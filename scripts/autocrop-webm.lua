-- autocrop-webm.lua — scan whole file with ffmpeg cropdetect, push union crop to webm.lua, tag originals UNCROPPED
-- No webm.lua fork needed. Uses its automation API:
--   script-message-to webm mpv-webm-set-range {startTime,endTime,region}
--   script-message-to webm mpv-webm-get-state  ->  webm-state {startTime,endTime,region,...}
local mp = require("mp")
local utils = require("mp.utils")
local msg = require("mp.msg")
local mpopts = require("mp.options")

local options = {
    -- global keybinds (change or disable by empty string via script-opts)
    keybind_scan = "C",
    keybind_tag = "U",
    ffmpeg_path = "ffmpeg",
    -- sampling: n = clamp(ceil(duration / sample_interval), min_samples, max_samples)
    sample_interval = 1.0,
    min_samples = 8,
    max_samples = 30,
    -- seconds of video decoded per probe
    probe_duration = 0.7,
    -- seconds at the end of the file to skip when sampling. TikTok-style
    -- end-cards/watermarks live there and a single polluted probe poisons
    -- the whole union. Falls back to the full duration on very short clips.
    ignore_last_seconds = 2.0,
    -- cropdetect params (ffmpeg scale: 24 ≈ classic)
    crop_limit = 24,
    crop_round = 2,
    -- union is rounded down to even, bars smaller than this are ignored
    ignore_bars_smaller_than = 4,
    -- after a successful webm encode, rename the source to *.UNCROPPED.*
    auto_tag_after_encode = true,
    tag_suffix = ".UNCROPPED",
}

mpopts.read_options(options, "autocrop-webm")

local scan = nil          -- active scan state or nil
local pending_source = nil -- source path captured at webm-encode-started, for auto-tag
local last_webm_state = nil

local function is_local_file(path)
    if not path then return false end
    local info = utils.file_info(path)
    return info ~= nil and not info.is_dir
end

local function show_progress(done, total, extra)
    -- NOTE: osd_message only. An earlier version also drew the same bar via
    -- set_osd_ass, which showed two bars (and fought uosc's ASS rendering).
    local pct = total > 0 and math.floor(done / total * 100) or 0
    local bars = 20
    local filled = math.floor(pct / 100 * bars + 0.5)
    local bar = string.rep("█", filled) .. string.rep("░", bars - filled)
    mp.osd_message(string.format("Autocrop %d/%d (%d%%) %s %s", done, total, pct, bar, extra or ""), 3)
end

local function clear_osd()
    -- clear any ASS overlay residue (older versions drew here); the progress
    -- itself is an osd_message and expires on its own
    local w, h = mp.get_osd_size()
    mp.set_osd_ass(w, h, "")
end

local function parse_last_crop(stderr)
    local last = nil
    for w, h, x, y in stderr:gmatch("crop=(%d+):(%d+):(%d+):(%d+)") do
        last = { w = tonumber(w), h = tonumber(h), x = tonumber(x), y = tonumber(y) }
    end
    return last
end

local function push_region_to_webm(region, duration)
    local range = {
        startTime = 0,
        endTime = duration,
        region = region,
    }
    -- preserve times the user may already have set in webm.lua UI
    if last_webm_state and last_webm_state.startTime and last_webm_state.startTime >= 0
        and last_webm_state.endTime and last_webm_state.endTime > last_webm_state.startTime then
        range.startTime = last_webm_state.startTime
        range.endTime = last_webm_state.endTime
    end
    local json = utils.format_json(range)
    -- script name for scripts/webm.lua is "webm"
    mp.commandv("script-message-to", "webm", "mpv-webm-set-range", json)
    msg.info("autocrop-webm: pushed region " .. json)
end

local function request_webm_state()
    last_webm_state = nil
    mp.commandv("script-message-to", "webm", "mpv-webm-get-state")
end

local function finish_scan()
    local st = scan
    scan = nil
    if not st or #st.results == 0 then
        clear_osd()
        mp.osd_message("Autocrop: no crop data (try manual crop in webm.lua)", 3)
        return
    end
    local min_x, min_y = math.huge, math.huge
    local max_x2, max_y2 = -1, -1
    for _, c in ipairs(st.results) do
        if c.x < min_x then min_x = c.x end
        if c.y < min_y then min_y = c.y end
        if c.x + c.w > max_x2 then max_x2 = c.x + c.w end
        if c.y + c.h > max_y2 then max_y2 = c.y + c.h end
    end
    -- round origin down / size to even, clamp to frame
    local x = math.floor(min_x / 2) * 2
    local y = math.floor(min_y / 2) * 2
    local w = math.floor((max_x2 - min_x) / 2) * 2
    local h = math.floor((max_y2 - min_y) / 2) * 2
    if x < 0 then x = 0 end
    if y < 0 then y = 0 end
    if x + w > st.vw then w = st.vw - x end
    if y + h > st.vh then h = st.vh - y end
    w = math.floor(w / 2) * 2
    h = math.floor(h / 2) * 2

    clear_osd()
    local dx, dy = st.vw - w, st.vh - h
    if dx <= options.ignore_bars_smaller_than and dy <= options.ignore_bars_smaller_than
        and x <= options.ignore_bars_smaller_than and y <= options.ignore_bars_smaller_than then
        -- hold this too: a watermark may be the reason, and the fix is manual
        mp.osd_message("Autocrop: no black bars found — press W then c, 1/2 to crop manually", 15)
        msg.info("autocrop-webm: full frame, no crop needed")
        return
    end

    local region = { x = x, y = y, w = w, h = h }
    push_region_to_webm(region, st.duration)
    -- sticky completion message: scans can take a while on longer files,
    -- hold the "press W" instruction so it isn't missed
    mp.osd_message(string.format("Autocrop done: %dx%d+%d+%d from %d samples — press W to encode", w, h, x, y, #st.results), 30)
    msg.info(string.format("autocrop-webm: union crop=%dx%d:%d:%d vw=%d vh=%d samples=%d", w, h, x, y, st.vw, st.vh, #st.results))
end

local function scan_step()
    if not scan or not scan.active then scan = nil clear_osd() return end
    if scan.idx > #scan.times then
        finish_scan()
        return
    end
    local i = scan.idx
    show_progress(i - 1, #scan.times, string.format("t=%.1fs", scan.times[i]))
    local t = scan.times[i]
    local args = {
        options.ffmpeg_path,
        "-hide_banner", "-nostats",
        "-ss", string.format("%.2f", t),
        "-i", scan.path,
        "-t", string.format("%.2f", options.probe_duration),
        "-vf", string.format("cropdetect=%d:%d:0", options.crop_limit, options.crop_round),
        "-f", "null", "-",
    }
    -- NOTE: ffmpeg prints cropdetect results to stderr, which
    -- utils.subprocess does NOT capture unless asked.
    local res = utils.subprocess({ args = args, cancellable = true, capture_stderr = true })
    local output = ""
    if res then output = (res.stderr or "") .. (res.stdout or "") end
    if output ~= "" then
        local c = parse_last_crop(output)
        if c then
            scan.results[#scan.results + 1] = c
        else
            msg.verbose("autocrop-webm: no crop line at t=" .. tostring(t))
        end
    elseif not res or res.status ~= 0 then
        msg.warn("autocrop-webm: ffmpeg probe failed at t=" .. tostring(t) .. " status=" .. tostring(res and res.status))
    else
        -- status 0 but no output: seek landed past EOF on the last sample, skip
        msg.verbose("autocrop-webm: empty probe at t=" .. tostring(t) .. ", skipped")
    end
    scan.idx = scan.idx + 1
    -- return to event loop so the OSD actually repaints between blocking probes
    mp.add_timeout(0.01, scan_step)
end

local function start_scan()
    if scan and scan.active then
        scan.active = false -- second press aborts
        mp.osd_message("Autocrop: aborted", 2)
        return
    end
    local path = mp.get_property("path")
    if not is_local_file(path) then
        mp.osd_message("Autocrop: streams/URLs not supported (open a local file)", 3)
        return
    end
    local duration = mp.get_property_number("duration")
    if not duration or duration <= 0 then
        mp.osd_message("Autocrop: unknown duration, cannot scan", 3)
        return
    end
    local vw = mp.get_property_number("video-params/w")
    local vh = mp.get_property_number("video-params/h")
    if not vw or not vh then
        mp.osd_message("Autocrop: no video track", 3)
        return
    end
    -- keep end-cards/watermarks out of the sampling window; fall back to
    -- the full duration when the clip is barely longer than the trim
    local sample_end = duration
    if options.ignore_last_seconds > 0 and duration - options.ignore_last_seconds >= 1.0 then
        sample_end = duration - options.ignore_last_seconds
    end
    local n = math.ceil(sample_end / options.sample_interval)
    n = math.max(options.min_samples, math.min(options.max_samples, n))
    -- short memes: don't oversample beyond 1 probe per ~0.5s
    if sample_end < options.min_samples * 0.5 then n = math.max(4, math.floor(sample_end / 0.5)) end
    local times = {}
    local latest_start = math.max(0, sample_end - options.probe_duration - 0.1)
    for k = 1, n do
        local t = (k - 0.5) / n * sample_end
        if t > latest_start then t = latest_start end
        times[#times + 1] = t
    end
    scan = { active = true, path = path, duration = duration, vw = vw, vh = vh, times = times, idx = 1, results = {} }
    msg.info(string.format("autocrop-webm: scanning %s dur=%.1f %dx%d samples=%d", path, duration, vw, vh, n))
    request_webm_state() -- best-effort: preserve start/end times already set in webm.lua
    mp.add_timeout(0.35, function()
        -- small delay so webm-state can arrive before we push; scan runs regardless
        if scan and scan.active then scan_step() end
    end)
    show_progress(0, n, "starting ffmpeg…")
end

local function uncropped_name_for(path)
    local dir, fname = utils.split_path(path)
    local stem, ext = fname:match("^(.*)%.([^%.]+)$")
    if not stem then stem, ext = fname, nil end
    local suffix = options.tag_suffix
    local candidate
    if ext then candidate = utils.join_path(dir, stem .. suffix .. "." .. ext)
    else candidate = utils.join_path(dir, stem .. suffix) end
    if candidate == path then candidate = candidate .. "_1" end
    local i = 1
    while utils.file_info(candidate) do
        i = i + 1
        if ext then candidate = utils.join_path(dir, stem .. suffix .. "_" .. i .. "." .. ext)
        else candidate = utils.join_path(dir, stem .. suffix .. "_" .. i) end
    end
    return candidate
end

local function tag_path_as_uncropped(path)
    if not is_local_file(path) then
        mp.osd_message("Tag UNCROPPED: not a local file", 2)
        return false
    end
    local dest = uncropped_name_for(path)
    local ok, err = os.rename(path, dest)
    if ok then
        mp.osd_message("Renamed to:\n" .. dest, 3)
        msg.info("autocrop-webm: renamed " .. path .. " -> " .. dest)
        return true
    else
        mp.osd_message("Tag UNCROPPED failed: " .. tostring(err), 3)
        msg.error("autocrop-webm: rename failed " .. tostring(err))
        return false
    end
end

local function tag_current()
    local path = mp.get_property("path")
    tag_path_as_uncropped(path)
end

-- webm.lua automation events (names are "webm-" + event from webm.lua's emit_event)
local pending_decide = false
local pending_region_valid = nil -- nil = state reply not arrived yet

local function region_is_cropped(r, vw, vh)
    if not (r and (r.x or -1) >= 0 and (r.y or -1) >= 0 and (r.w or 0) > 0 and (r.h or 0) > 0) then
        return false
    end
    -- a "reset to fullscreen" region cuts nothing: not a crop either
    if vw and vh and r.x == 0 and r.y == 0 and r.w == vw and r.h == vh then
        return false
    end
    return true
end

local function clear_pending()
    pending_source = nil
    pending_region_valid = nil
    pending_decide = false
end

-- webm.lua deletes <out>-video-pass1.log on success, but NOT when the
-- encode fails/is interrupted, and mpv recreates that (for x264: always
-- empty, useless) placeholder on every two-pass run. Sweep it as a backstop.
-- Only 0-byte files: never touch a live libvpx/libaom stats file that
-- actually holds data (e.g. from a concurrent encode in the same dir).
local function sweep_pass1_logs(dir)
    if not dir or dir == "" then return end
    local ok, files = pcall(utils.readdir, dir)
    if not ok or not files then return end
    for _, f in ipairs(files) do
        if f:match("%-video%-pass1%.log$") then
            local p = utils.join_path(dir, f)
            local info = utils.file_info(p)
            if info and not info.is_dir and (info.size or 0) == 0 then
                os.remove(p)
                msg.verbose("autocrop-webm: swept leftover " .. p)
            end
        end
    end
end

local function maybe_auto_tag()
    -- only tag when the encode actually cropped: trim-only encodes
    -- leave the source name alone
    if pending_region_valid then
        msg.info("autocrop-webm: cropped encode success, auto-tagging " .. tostring(pending_source))
        tag_path_as_uncropped(pending_source)
    else
        msg.verbose("autocrop-webm: encode had no crop region, source left alone")
    end
    clear_pending()
end

mp.register_script_message("webm-state", function(json)
    local ok, st = pcall(utils.parse_json, json)
    if not (ok and st) then return end
    last_webm_state = st
    if pending_source and pending_region_valid == nil and st.region then
        local vw = mp.get_property_number("video-params/w")
        local vh = mp.get_property_number("video-params/h")
        pending_region_valid = region_is_cropped(st.region, vw, vh)
        if pending_decide then
            maybe_auto_tag()
        end
    end
end)
mp.register_script_message("webm-range-set", function()
    msg.info("autocrop-webm: webm.lua confirmed range-set")
end)
-- also sweep on every file load: covers leftovers from crashed/killed
-- mpv sessions, which never got an encode-finished event
mp.register_event("file-loaded", function()
    local path = mp.get_property("path")
    if not path then return end
    local dir = utils.split_path(path)
    sweep_pass1_logs(dir)
end)
mp.register_script_message("webm-encode-started", function()
    pending_source = mp.get_property("path")
    pending_region_valid = nil
    pending_decide = false
    -- ask webm.lua which region is in effect; the reply can only be
    -- processed after the (blocking) encode, so the finished handler
    -- below defers the tag decision to it
    mp.commandv("script-message-to", "webm", "mpv-webm-get-state")
end)
mp.register_script_message("webm-encode-finished", function(result)
    -- backstop for placeholder leftovers on the failure paths (webm.lua
    -- only cleans them after a fully successful encode)
    if pending_source then
        local dir = utils.split_path(pending_source)
        sweep_pass1_logs(dir)
    end
    if result == "success" and options.auto_tag_after_encode and pending_source then
        if pending_region_valid == nil then
            pending_decide = true
            mp.add_timeout(2.0, function()
                if pending_decide then
                    msg.verbose("autocrop-webm: no webm state arrived, skipping auto-tag")
                    clear_pending()
                end
            end)
        else
            maybe_auto_tag()
        end
    else
        clear_pending()
    end
end)

if options.keybind_scan and options.keybind_scan ~= "" then
    mp.add_key_binding(options.keybind_scan, "autocrop-webm-scan", start_scan)
end
if options.keybind_tag and options.keybind_tag ~= "" then
    mp.add_key_binding(options.keybind_tag, "autocrop-webm-tag", tag_current)
end
-- always expose script-bindings even if keybinds are blanked
mp.add_key_binding(nil, "autocrop-webm-scan-fallback", start_scan)
mp.add_key_binding(nil, "autocrop-webm-tag-fallback", tag_current)
