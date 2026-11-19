-- copyparty.lua — upload the playing file to a self-hosted copyparty.
--
-- Flow: press P while anything is playing and the file is uploaded as-is
-- with multipart POST + ?want=url. No encoding, no webm.lua involved.
-- Emoji/accented/fullwidth/Cyrillic filenames are rewritten to plain ASCII
-- with a deterministic mapping first, so the server never sees a name it
-- might redirect on and the same local name always lands on the same
-- remote name (see normalize_filenames).
-- The password comes from a gitignored .env file and only ever reaches
-- curl through a 0600 temp config file: never on a command line,
-- never in mpv logs, never in git.
local mp = require("mp")
local utils = require("mp.utils")
local msg = require("mp.msg")
local mpopts = require("mp.options")

local options = {
    -- Upload the playing file as-is.
    keybind = "P",
    -- Your copyparty folder URL, trailing slash recommended.
    copyparty_url = "",
    -- Account name on servers with --usernames. Empty means the password
    -- alone is used (header "PW: <password>"); otherwise
    -- "PW: <user>:<password>" is sent.
    copyparty_user = "",
    -- Optional SOCKS proxy for the upload, e.g. [[socks5h://127.0.0.1:9050]].
    -- Only port 4447 (i2p) and 9050 (tor) are accepted, and socks5:// is
    -- upgraded to socks5h:// so hostnames never leak through local DNS.
    -- Plain http:// uploads are refused unless a matching proxy is set:
    -- .onion requires :9050, .i2p requires :4447 (loopback http:// is exempt).
    copyparty_proxy = "",
    -- File holding COPYPARTY_PASSWORD=... (gitignored, never committed).
    -- A starting "~" is expanded.
    password_file = "~/.config/mpv/copyparty.env",
    curl_path = "curl",
    copy_to_clipboard = true,
    open_after_upload = false,
    -- Rewrite weird characters (emoji, accents, fullwidth, cyrillic, ...) to
    -- plain ASCII before uploading. Deterministic: the same local name always
    -- becomes the same remote name, so the overwrite prompt keeps working.
    -- Turn off to keep the raw name (works only if your server/proxy copes).
    normalize_filenames = true,
}
mpopts.read_options(options, "copyparty")

local is_windows = type(package) == "table" and type(package.config) == "string"
    and package.config:sub(1, 1) == "\\"

local function expand_home(path)
    if not path then return path end
    local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
    return (path:gsub("^~", home))
end

local function read_env_value(path, key)
    local file = io.open(path, "r")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    if not content then return nil end
    for line in (content .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        local s = line:match("^%s*(.-)%s*$")
        if s ~= "" and s:sub(1, 1) ~= "#" then
            local k, v = s:match("^([A-Za-z_][A-Za-z0-9_]*)%s*=%s*(.-)%s*$")
            if k == key and v ~= "" then
                local q = v:sub(1, 1)
                if (q == "\"" or q == "'") and #v >= 2 and v:sub(-1) == q then
                    v = v:sub(2, -2)
                end
                return v
            end
        end
    end
    return nil
end

-- normalized "socks5h://host:port", "" for direct, or nil+err.
-- Only the i2p (4447) and tor (9050) endpoints are accepted, and plain
-- socks5:// is upgraded to socks5h:// so .onion/.i2p names always
-- resolve through the proxy instead of leaking to local DNS.
local function normalized_proxy()
    local proxy = options.copyparty_proxy or ""
    if proxy == "" then return "" end
    local host, port = proxy:match("^socks5h?://([^:/%s]+):(%d+)%s*$")
    if not host then
        return nil, "copyparty_proxy must look like socks5h://127.0.0.1:9050"
    end
    port = tonumber(port)
    if port ~= 4447 and port ~= 9050 then
        return nil, "copyparty_proxy port must be 4447 (i2p) or 9050 (tor)"
    end
    return "socks5h://" .. host .. ":" .. port
end

-- returns proxy ("" = direct) or nil+reason. Plain http:// is refused
-- outright unless it stays on loopback or goes through the matching proxy.
local function check_transport(url)
    local scheme, rest = url:match("^(%a+)://(.+)$")
    if not scheme then
        return nil, "copyparty_url must start with http(s)://"
    end
    local host = ((rest:match("^([^/:?#%s]+)") or ""):lower())
    local proxy, perr = normalized_proxy()
    if perr then return nil, perr end
    if scheme:lower() == "https" then return proxy end
    if host == "localhost" or host == "127.0.0.1" or host == "[::1]" then
        return proxy -- loopback: nothing leaves the machine
    end
    -- actual special-use domains only, matched at the END: .onion (tor),
    -- .i2p and .b32.i2p long-form destinations (i2p). A clearnet name
    -- merely containing those strings (noti2p.example.com) is NOT special.
    local kind = nil
    if host:match("%.onion$") then
        kind = "onion"
    elseif host:match("%.b32%.i2p$") or host:match("%.i2p$") then
        kind = "i2p"
    end
    if kind then
        local want = kind == "onion" and 9050 or 4447
        local net = kind == "onion" and "tor" or "i2p"
        if proxy == "" then
            return nil, "plain http to ." .. kind .. " needs copyparty_proxy (socks5h://127.0.0.1:" .. want .. " for " .. net .. ")"
        end
        if tonumber(proxy:match(":(%d+)$")) ~= want then
            return nil, "plain http to ." .. kind .. " needs the :" .. want .. " " .. net .. " proxy"
        end
        return proxy
    end
    return nil, "refusing plain http:// — use https:// (or a .onion/.i2p/.b32.i2p address with its proxy)"
end

local function secret_or_error()
    if options.copyparty_url == "" then
        return nil, "Set copyparty_url in copyparty.conf first."
    end
    if not options.copyparty_url:match("^https?://") then
        return nil, "copyparty_url must start with http(s)://"
    end
    local pw = read_env_value(expand_home(options.password_file), "COPYPARTY_PASSWORD")
    if not pw or pw == "" then
        return nil, "No COPYPARTY_PASSWORD in " .. tostring(options.password_file)
    end
    if options.copyparty_user ~= "" then
        -- HTTP basic auth works with and without --usernames on the server;
        -- a "PW: user:pass" header would 403 on servers that expect the
        -- bare volume password instead
        return "basic", tostring(options.copyparty_user) .. ":" .. pw
    end
    return "header", pw
end

local function temp_config_path()
    local tmp = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
    return utils.join_path(tmp, "mpv-copyparty-upload.conf")
end

local temp_config = nil
local function delete_temp_config()
    if temp_config then
        os.remove(temp_config)
        temp_config = nil
    end
end
-- best effort: clear a leftover from a crashed session
delete_temp_config()

local function write_temp_config(method, secret)
    local path = temp_config_path()
    local file = io.open(path, "w")
    if not file then return nil end
    local esc = secret:gsub("[\\\"]", "\\%0")
    if method == "basic" then
        -- curl -u equivalent, keeps credentials out of argv/logs
        file:write("user = \"" .. esc .. "\"\n")
    else
        file:write("header = \"PW: " .. esc .. "\"\n")
    end
    file:close()
    if not is_windows then
        utils.subprocess({ args = { "chmod", "600", path }, cancellable = false })
    end
    temp_config = path
    return path
end

local function escape_form_path(path)
    return path:gsub("([,;])", "\\%1")
end

-- deterministic filename normalisation ---------------------------------------
-- Source names often carry emoji, accents or fullwidth characters; copyparty
-- (or a reverse proxy in front of it) sometimes answers those with a redirect
-- instead of the uploaded file. Everything below is a pure function of the
-- original name, so uploading the same name twice always produces the same
-- remote name and the overwrite prompt keeps working instead of piling up
-- "-2" copies.

-- walk a UTF-8 string as codepoints; -1 means "invalid byte". Callers treat
-- that as lossy rather than guessing, so broken names stay deterministic too.
local function codepoints(s)
    local i, n = 1, #s
    return function()
        if i > n then return nil end
        local b = s:byte(i)
        local cp, extra
        if b < 0x80 then
            cp, extra = b, 0
        elseif b >= 0xC2 and b <= 0xDF then
            cp, extra = b - 0xC0, 1
        elseif b >= 0xE0 and b <= 0xEF then
            cp, extra = b - 0xE0, 2
        elseif b >= 0xF0 and b <= 0xF4 then
            cp, extra = b - 0xF0, 3
        else
            i = i + 1
            return -1
        end
        if i + extra > n then
            i = n + 1
            return -1
        end
        for k = 1, extra do
            local c = s:byte(i + k)
            if c < 0x80 or c > 0xBF then
                i = i + 1
                return -1
            end
            cp = cp * 64 + (c - 0x80)
        end
        i = i + extra + 1
        return cp
    end
end

-- codepoint -> ascii for the scripts that show up in real filenames. Only
-- characters we can actually spell out are listed; anything else is dropped
-- and flagged lossy. Decomposed accents (U+0300..U+036F) are dropped, so NFC
-- and NFD spellings of the same name normalise identically.
-- Entries are { lowercase ascii, lowercase letters, uppercase letters };
-- the uppercase ascii form is derived, so "ÉTÉ" stays "ETE" instead of
-- silently colliding with "été".
local translit = {}
do
    local groups = {
        -- latin-1 / latin extended
        { "a", "àáâãäåāăą", "ÀÁÂÃÄÅĀĂĄ" },
        { "ae", "æ", "Æ" },
        { "c", "çćĉċč", "ÇĆĈĊČ" },
        { "d", "ďđð", "ĎĐÐ" },
        { "e", "èéêëēĕėęě", "ÈÉÊËĒĔĖĘĚ" },
        { "g", "ĝğġģ", "ĜĞĠĢ" },
        { "h", "ĥħ", "ĤĦ" },
        { "i", "ìíîïĩīĭįı", "ÌÍÎÏĨĪĬĮİ" },
        { "j", "ĵ", "Ĵ" },
        { "k", "ķ", "Ķ" },
        { "l", "ĺļľŀł", "ĹĻĽĿŁ" },
        { "n", "ñńņň", "ÑŃŅŇ" },
        { "o", "òóôõöøōŏő", "ÒÓÔÕÖØŌŎŐ" },
        { "oe", "œ", "Œ" },
        { "r", "ŕŗř", "ŔŖŘ" },
        { "s", "śŝşš", "ŚŜŞŠ" },
        { "ss", "ß", "ẞ" },
        { "t", "ţťŧ", "ŢŤŦ" },
        { "th", "þ", "Þ" },
        { "u", "ùúûüũūŭůűų", "ÙÚÛÜŨŪŬŮŰŲ" },
        { "w", "ŵ", "Ŵ" },
        { "y", "ýŷÿ", "ÝŶŸ" },
        { "z", "źżž", "ŹŻŽ" },
        -- cyrillic
        { "a", "а", "А" },
        { "b", "б", "Б" },
        { "v", "в", "В" },
        { "g", "гґ", "ГҐ" },
        { "d", "д", "Д" },
        { "e", "еэ", "ЕЭ" },
        { "yo", "ё", "Ё" },
        { "zh", "ж", "Ж" },
        { "z", "з", "З" },
        { "i", "иії", "ИІЇ" },
        { "y", "йы", "ЙЫ" },
        { "k", "к", "К" },
        { "l", "л", "Л" },
        { "m", "м", "М" },
        { "n", "н", "Н" },
        { "o", "о", "О" },
        { "p", "п", "П" },
        { "r", "р", "Р" },
        { "s", "с", "С" },
        { "t", "т", "Т" },
        { "u", "у", "У" },
        { "f", "ф", "Ф" },
        { "kh", "х", "Х" },
        { "ts", "ц", "Ц" },
        { "ch", "ч", "Ч" },
        { "sh", "ш", "Ш" },
        { "shch", "щ", "Щ" },
        { "", "ъь", "ЪЬ" },
        { "yu", "ю", "Ю" },
        { "ya", "я", "Я" },
        { "ye", "є", "Є" },
        { "dj", "ђ", "Ђ" },
        { "j", "ј", "Ј" },
        { "lj", "љ", "Љ" },
        { "nj", "њ", "Њ" },
        { "c", "ћ", "Ћ" },
        { "dz", "џ", "Џ" },
    }
    for _, group in ipairs(groups) do
        for _, pair in ipairs({ { group[1], group[2] }, { group[1]:upper(), group[3] } }) do
            local iter = codepoints(pair[2])
            while true do
                local cp = iter()
                if not cp then break end
                if cp ~= -1 and translit[cp] == nil then translit[cp] = pair[1] end
            end
        end
    end
end

-- stable 6-char base36 suffix, so two different names that collapse to the
-- same ascii text (e.g. "東京.mp4" and "🔥.mp4") stay distinct.
-- Plain arithmetic only: the script has to run on Lua 5.1, 5.2 and LuaJIT.
local base36 = "0123456789abcdefghijklmnopqrstuvwxyz"
local function short_hash(s)
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % 2147483647
    end
    local out = {}
    for _ = 1, 6 do
        local d = h % 36
        out[#out + 1] = base36:sub(d + 1, d + 1)
        h = math.floor(h / 36)
    end
    return table.concat(out)
end

-- ASCII version of one component. Second return is true only when something
-- we cannot spell out had to be dropped (emoji, unknown script, invalid
-- bytes); plain punctuation is folded to "-" without flagging, so ordinary
-- western names stay readable.
local function ascii_component(text, keep_dot)
    local out = {}
    local lossy = false
    local iter = codepoints(text)
    while true do
        local cp = iter()
        if not cp then break end
        local piece
        if cp == -1 then
            lossy = true
        elseif (cp >= 0x30 and cp <= 0x39) or (cp >= 0x41 and cp <= 0x5A)
            or (cp >= 0x61 and cp <= 0x7A) then
            piece = string.char(cp)
        elseif cp == 0x2D or cp == 0x5F or (keep_dot and cp == 0x2E) then
            piece = string.char(cp)
        elseif cp == 0x27 or cp == 0x60 or cp == 0xB4
            or cp == 0x2018 or cp == 0x2019 then
            piece = "" -- apostrophes just vanish: "what's" -> "whats"
        elseif cp < 0x80 then
            piece = "-" -- space and every other ascii punctuation
        elseif cp >= 0x300 and cp <= 0x36F then
            piece = "" -- combining accent, base letter is already there
        elseif translit[cp] then
            piece = translit[cp]
        elseif cp == 0xA0 or cp == 0x3000 then
            piece = "-"
        elseif cp >= 0xFF01 and cp <= 0xFF5E then
            -- fullwidth forms map straight onto ascii
            local a = cp - 0xFEE0
            if (a >= 0x30 and a <= 0x39) or (a >= 0x41 and a <= 0x5A)
                or (a >= 0x61 and a <= 0x7A) then
                piece = string.char(a)
            else
                piece = "-"
            end
        else
            lossy = true
        end
        if piece then out[#out + 1] = piece end
    end
    local s = table.concat(out)
    s = s:gsub("%-+", "-")
    s = s:gsub("^[%-%._]+", ""):gsub("[%-%._]+$", "")
    return s, lossy
end

-- 120 bytes + ".ext" is well under every filesystem and header limit in play
local FILENAME_STEM_MAX = 120
local HASH_SUFFIX_LEN = 7 -- "-" + 6 base36 chars

local function clean_extension(ext)
    ext = ext:lower():gsub("[^a-z0-9]", "")
    if #ext > 10 then ext = ext:sub(1, 10) end
    return ext
end

local function trim_stem(s)
    return (s:gsub("^[%-%._]+", ""):gsub("[%-%._]+$", ""))
end

-- idempotent: normalize_filename(normalize_filename(x)) == normalize_filename(x)
local function normalize_filename(fname)
    local stem, ext = fname, ""
    local dot = fname:match("^.*()%.")
    if dot and dot > 1 and dot < #fname then
        stem = fname:sub(1, dot - 1)
        ext = fname:sub(dot + 1)
    end
    local clean_stem, lossy = ascii_component(stem, true)
    local clean_ext = clean_extension(ext)
    local truncated = false
    if #clean_stem > FILENAME_STEM_MAX then
        clean_stem = trim_stem(clean_stem:sub(1, FILENAME_STEM_MAX))
        truncated = true
    end
    if lossy or truncated or clean_stem == "" then
        -- leave room for the suffix so a second pass never re-truncates and
        -- therefore never hashes something different
        local room = FILENAME_STEM_MAX - HASH_SUFFIX_LEN
        if #clean_stem > room then clean_stem = trim_stem(clean_stem:sub(1, room)) end
        local suffix = short_hash(fname)
        clean_stem = (clean_stem ~= "" and clean_stem .. "-" or "file-") .. suffix
    end
    if clean_ext ~= "" then
        return clean_stem .. "." .. clean_ext
    end
    return clean_stem
end

local function copy_link(url)
    if not options.copy_to_clipboard then return false end
    local ok, written = pcall(function()
        return mp.set_property("clipboard/text", url)
    end)
    if ok and written then
        msg.info("copyparty: link copied via clipboard/text property")
        return true
    end
    -- mpv has no native clipboard on most setups: fall back to tools,
    -- same chain webm.lua uses. Blocking call so we know it really worked
    -- (async spawn succeeds even when the tool itself then fails).
    local candidates
    if is_windows then
        candidates = { { "clip" } }
    elseif utils.file_info("/Applications") then
        candidates = { { "pbcopy" } }
    else
        candidates = {
            { "wl-copy" },
            { "xclip", "-selection", "clipboard" },
            { "xsel", "--clipboard", "--input" },
        }
    end
    for _, args in ipairs(candidates) do
        local res = utils.subprocess({
            args = args,
            stdin_data = url,
            cancellable = false,
        })
        if res and res.status == 0 then
            msg.info("copyparty: link copied via " .. tostring(args[1]))
            return true
        end
    end
    msg.warn("copyparty: no clipboard tool found (wl-copy/xclip/xsel), link NOT copied")
    return false
end

local function open_link(url)
    if not options.open_after_upload then return end
    local cmd
    if is_windows then
        cmd = { "cmd", "/c", "start", "", url }
    elseif utils.file_info("/Applications") then
        cmd = { "open", url }
    else
        cmd = { "xdg-open", url }
    end
    utils.subprocess_detached({ args = cmd })
end

-- upload state
local uploading = false
local upload_handle = nil
local upload_tmp = nil
local upload_response = nil
local upload_progress = nil
local upload_timer = nil
local upload_percent = -1

local function poll_upload_progress()
    if not uploading or not upload_progress then return end
    local f = io.open(upload_progress, "r")
    if not f then return end
    local content = f:read("*a") or ""
    f:close()
    local percent = nil
    for match in content:gmatch("(%d+%.?%d*)%%") do
        percent = tonumber(match)
    end
    if percent and math.floor(percent) ~= upload_percent then
        upload_percent = math.floor(percent)
        local bars = 20
        local filled = math.floor(upload_percent / 100 * bars + 0.5)
        local bar = string.rep("\226\150\136", filled) .. string.rep("\226\150\145", bars - filled)
        mp.osd_message(string.format("Uploading to copyparty %d%% %s\nESC cancels",
            upload_percent, bar), 2)
    end
end

local function cancel_upload()
    if not uploading then return end
    uploading = false
    if upload_handle then
        mp.abort_async_command(upload_handle)
        upload_handle = nil
    end
    if upload_timer then upload_timer:kill() upload_timer = nil end
    if upload_tmp then os.remove(upload_tmp) upload_tmp = nil end
    if upload_response then os.remove(upload_response) upload_response = nil end
    if upload_progress then os.remove(upload_progress) upload_progress = nil end
    mp.remove_key_binding("copyparty-cancel")
    mp.osd_message("Copyparty upload cancelled.", 3)
    msg.info("copyparty: upload cancelled")
end

local function finish_upload(success, url_or_err)
    uploading = false
    upload_handle = nil
    if upload_timer then upload_timer:kill() upload_timer = nil end
    if upload_tmp then os.remove(upload_tmp) upload_tmp = nil end
    if upload_response then os.remove(upload_response) upload_response = nil end
    if upload_progress then os.remove(upload_progress) upload_progress = nil end
    mp.remove_key_binding("copyparty-cancel")
    if success then
        local copied = copy_link(url_or_err)
        open_link(url_or_err)
        local note = copied and "(link copied to clipboard)" or "(copy it manually!)"
        mp.osd_message("Copyparty upload complete:\n" .. url_or_err .. "\n" .. note, 5)
        msg.info("copyparty: uploaded " .. url_or_err)
    else
        mp.osd_message("Copyparty upload failed:\n" .. tostring(url_or_err), 10)
        msg.warn("copyparty: upload failed: " .. tostring(url_or_err))
    end
end

local function on_upload_done(success, result, err)
    if not uploading then return end
    local http_code = result and tonumber(result.stdout)
    local body = ""
    if upload_response then
        local f = io.open(upload_response, "r")
        if f then body = f:read("*a") or "" f:close() end
    end
    local link = body:match("^%s*(https?://%S+)")
    if success and result and result.status == 0 and http_code
        and http_code >= 200 and http_code < 300 and link then
        finish_upload(true, link)
    else
        local why = body:gsub("%s+", " "):sub(1, 200)
        if why == "" then
            why = (result and result.error_string) or tostring(err) or "upload failed"
        end
        if http_code == 403 then
            why = why .. " — check copyparty_user (set it iff the server uses --usernames, else leave it empty)"
        elseif http_code and http_code >= 300 and http_code < 400 then
            why = why .. " (redirected: copyparty_url should point at the volume, not a login page)"
        elseif not http_code or http_code == 0 then
            local proxy = normalized_proxy()
            if proxy and proxy ~= "" then
                why = (why ~= "" and why .. " " or "") .. "(connection failed via proxy — is it running?)"
            end
        end
        finish_upload(false, "HTTP " .. tostring(http_code) .. " " .. why)
    end
end

-- percent-encode everything but unreserved chars and slashes, for HEAD
-- existence checks (multipart -F sends the raw name and needs no encoding)
local function escape_url_path(s)
    return (s:gsub("[^A-Za-z0-9%-%._~%/]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- "yes" exists / "no" free / "unknown" (network/auth trouble: let the
-- upload itself be the judge, its error message names the real problem)
local function remote_exists(url, cfg, proxy)
    local args = {
        options.curl_path, "--config", cfg, "-I",
        "--url", url, "-s", "-w", "%{http_code}",
        "--max-time", "15",
    }
    if proxy and proxy ~= "" then
        args[#args + 1] = "--proxy"
        args[#args + 1] = proxy
    end
    local res = utils.subprocess({ args = args, cancellable = false })
    if not res or res.status ~= 0 then return "unknown" end
    -- the -w code is the last thing on stdout; headers above it are full
    -- of unrelated numbers, so anchor the match at the end
    local code = tonumber((res.stdout or ""):match("(%d+)%s*$"))
    if code and code >= 200 and code < 300 then return "yes" end
    if code == 404 then return "no" end
    return "unknown"
end

local pending_choice = nil
local upload_decide_timer = nil

local function clear_choice_binds()
    mp.remove_key_binding("copyparty-overwrite")
    mp.remove_key_binding("copyparty-rename")
    mp.remove_key_binding("copyparty-copylink")
    mp.remove_key_binding("copyparty-nodecision")
end

local function kill_decide_timer()
    if upload_decide_timer then upload_decide_timer:kill() upload_decide_timer = nil end
end

local function cancel_pending(text)
    pending_choice = nil
    clear_choice_binds()
    kill_decide_timer()
    delete_temp_config()
    mp.osd_message(text or "Copyparty: cancelled, nothing uploaded.", 3)
    msg.info("copyparty: upload cancelled before start")
end

-- forward declaration: ask_overwrite's keybinds call do_upload, defined below
local do_upload

local function free_remote_name(base, sep, fname, proxy)
    local stem, ext = fname:match("^(.*)(%.[^%.]+)$")
    if not stem then stem, ext = fname, "" end
    for i = 2, 100 do
        local cand = stem .. "-" .. i .. ext
        if remote_exists(base .. escape_url_path(cand), temp_config, proxy) ~= "yes" then
            return cand
        end
    end
    return nil
end

local function ask_overwrite(path, base, sep, remote, proxy)
    pending_choice = { path = path, base = base, sep = sep, remote = remote, proxy = proxy }
    mp.osd_message("Exists on server:\n" .. remote .. "\n[y] overwrite / [r] auto-rename / [c] copy link / [ESC] cancel (default)", 60)
    mp.add_key_binding("y", "copyparty-overwrite", function()
        local p = pending_choice
        pending_choice = nil
        clear_choice_binds()
        kill_decide_timer()
        if p then
            msg.info("copyparty: overwriting " .. p.remote)
            do_upload(p.path, p.base, p.sep, p.remote, p.proxy)
        end
    end)
    mp.add_key_binding("r", "copyparty-rename", function()
        local p = pending_choice
        pending_choice = nil
        clear_choice_binds()
        kill_decide_timer()
        if not p then return end
        local alt = free_remote_name(p.base, p.sep, p.remote, p.proxy)
        if not alt then
            delete_temp_config()
            mp.osd_message("Copyparty: no free name found, cancelled.", 4)
            return
        end
        msg.info("copyparty: uploading as " .. alt)
        do_upload(p.path, p.base, p.sep, alt, p.proxy)
    end)
    mp.add_key_binding("c", "copyparty-copylink", function()
        local p = pending_choice
        pending_choice = nil
        clear_choice_binds()
        kill_decide_timer()
        if not p then return end
        delete_temp_config()
        local link = p.base .. escape_url_path(p.remote)
        local copied = copy_link(link)
        local note = copied and "(link copied to clipboard)" or "(copy it manually!)"
        mp.osd_message("Copyparty: nothing uploaded, existing link:\n" .. link .. "\n" .. note, 8)
        msg.info("copyparty: existing link " .. link)
    end)
    mp.add_key_binding("ESC", "copyparty-nodecision", function()
        cancel_pending("Copyparty: cancelled, nothing uploaded.")
    end)
    upload_decide_timer = mp.add_timeout(60, function()
        if pending_choice then
            cancel_pending("Copyparty: no choice made, nothing uploaded.")
        end
    end)
end

do_upload = function(path, base, sep, target, proxy)
    local response = os.tmpname()
    local progress = os.tmpname()
    local f0 = io.open(progress, "w")
    if f0 then f0:close() end
    local args = {
        options.curl_path,
        "--config", temp_config,
        "-F", "f=@" .. tostring(escape_form_path(path)) .. ";filename=" .. target,
        "--url", base .. sep .. "want=url",
        "-o", response,
        "-w", "%{http_code}",
        "-#",
        "--stderr", progress,
    }
    if proxy and proxy ~= "" then
        args[#args + 1] = "--proxy"
        args[#args + 1] = proxy
    end
    uploading = true
    upload_tmp = temp_config
    upload_response = response
    upload_progress = progress
    upload_percent = -1
    temp_config = nil -- ownership moved to the upload; finish/cancel deletes via upload_tmp
    mp.osd_message("Uploading to copyparty as:\n" .. tostring(target) .. "\nESC cancels", 60)
    mp.add_key_binding("ESC", "copyparty-cancel", cancel_upload)
    upload_timer = mp.add_periodic_timer(0.3, poll_upload_progress)
    upload_handle = mp.command_native_async({
        name = "subprocess",
        args = args,
        playback_only = false,
        capture_stdout = true,
        capture_stderr = false,
        capture_size = 64,
    }, on_upload_done)
    if not upload_handle then
        finish_upload(false, "could not start curl")
    end
end

local function start_upload(path)
    local method, secret = secret_or_error()
    if not method then
        mp.osd_message("Copyparty: " .. tostring(secret), 5)
        msg.warn("copyparty: " .. tostring(secret))
        return
    end
    local proxy, perr = check_transport(options.copyparty_url)
    if not proxy then
        mp.osd_message("Copyparty: " .. tostring(perr), 6)
        msg.warn("copyparty: " .. tostring(perr))
        return
    end
    local cfg = write_temp_config(method, secret)
    secret = nil -- don't keep it around longer than needed
    if not cfg then
        mp.osd_message("Copyparty: could not write temp curl config.", 5)
        return
    end
    local base = options.copyparty_url
    if base:sub(-1) ~= "/" then base = base .. "/" end
    local sep = base:find("?", 1, true) and "&" or "?"
    local _, fname = utils.split_path(path)
    -- ASCII-only remote name: emoji/accented/fullwidth characters make
    -- copyparty or its proxy answer with a redirect on some setups. The
    -- mapping is deterministic, so the same local name always lands on the
    -- same remote name and the overwrite prompt stays meaningful.
    local remote_name = options.normalize_filenames and normalize_filename(fname) or fname
    if remote_name ~= fname then
        msg.info("copyparty: sanitized filename " .. fname .. " -> " .. remote_name)
    end
    local state = remote_exists(base .. escape_url_path(remote_name), cfg, proxy)
    if state == "yes" then
        ask_overwrite(path, base, sep, remote_name, proxy)
        return
    end
    do_upload(path, base, sep, remote_name, proxy)
end

local function trigger()
    -- upload the playing file as-is; works for anything mpv opened
    if uploading then
        mp.osd_message("Copyparty: upload already in progress.", 3)
        return
    end
    local src = mp.get_property("path")
    if not src then
        mp.osd_message("Copyparty: nothing playing.", 3)
        return
    end
    local info = utils.file_info(src)
    if not info or info.is_dir then
        mp.osd_message("Copyparty: only local files supported.", 3)
        return
    end
    msg.info("copyparty: uploading current file " .. src)
    start_upload(src)
end

if options.keybind and options.keybind ~= "" then
    mp.add_key_binding(options.keybind, "copyparty-upload", trigger)
end
mp.add_key_binding(nil, "copyparty-upload-fallback", trigger)
mp.register_script_message("copyparty-set-options", function(json)
    local ok, tbl = pcall(utils.parse_json, json)
    if not ok or type(tbl) ~= "table" then return end
    for k, v in pairs(tbl) do options[k] = v end
end)
