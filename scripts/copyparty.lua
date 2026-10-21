-- copyparty.lua — upload the playing file to a self-hosted copyparty.
--
-- Flow: press P while anything is playing and the file is uploaded as-is
-- with multipart POST + ?want=url. No encoding, no webm.lua involved.
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
    -- File holding COPYPARTY_PASSWORD=... (gitignored, never committed).
    -- A starting "~" is expanded.
    password_file = "~/.config/mpv/copyparty.env",
    curl_path = "curl",
    copy_to_clipboard = true,
    open_after_upload = false,
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
        return tostring(options.copyparty_user) .. ":" .. pw
    end
    return pw
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

local function write_temp_config(secret)
    local path = temp_config_path()
    local file = io.open(path, "w")
    if not file then return nil end
    file:write("header = \"PW: " .. secret:gsub("[\\\"]", "\\%0") .. "\"\n")
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
    -- same chain webm.lua uses. Never logs the URL content beyond debug.
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
        local handle = mp.command_native_async({
            name = "subprocess",
            args = args,
            stdin_data = url,
            playback_only = false,
        }, function() end)
        if handle then
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
        mp.osd_message("Copyparty upload complete:\n" .. url_or_err .. "\n" .. note, 30)
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
        finish_upload(false, "HTTP " .. tostring(http_code) .. " " .. why)
    end
end

local function start_upload(path)
    local secret, err = secret_or_error()
    if not secret then
        mp.osd_message("Copyparty: " .. tostring(err), 5)
        return
    end
    local cfg = write_temp_config(secret)
    secret = nil -- don't keep it around longer than needed
    if not cfg then
        mp.osd_message("Copyparty: could not write temp curl config.", 5)
        return
    end
    local base = options.copyparty_url
    if base:sub(-1) ~= "/" then base = base .. "/" end
    local sep = base:find("?", 1, true) and "&" or "?"
    local response = os.tmpname()
    local progress = os.tmpname()
    local f0 = io.open(progress, "w")
    if f0 then f0:close() end
    local args = {
        options.curl_path,
        "--config", cfg,
        "-F", "f=@" .. tostring(escape_form_path(path)),
        "--url", base .. sep .. "want=url",
        "-o", response,
        "-w", "%{http_code}",
        "-#",
        "--stderr", progress,
    }
    uploading = true
    upload_tmp = cfg
    upload_response = response
    upload_progress = progress
    upload_percent = -1
    local _, fname = utils.split_path(path)
    mp.osd_message("Uploading to copyparty:\n" .. tostring(fname) .. "\nESC cancels", 60)
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
    local secret, err = secret_or_error()
    if not secret then
        mp.osd_message("Copyparty: " .. tostring(err), 5)
        return
    end
    secret = nil
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
