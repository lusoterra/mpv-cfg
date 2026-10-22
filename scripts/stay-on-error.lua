-- stay-on-error.lua — don't skip broken files, stay paused with a message
-- No forks, no dependencies. Works alongside uosc/autoload/thumbfast.
--
-- Problem: mpv skips files that fail to load (corrupt video, truncated
-- download, bad image) and jumps to the next playlist entry, so you never
-- notice which file was broken.
--
-- Fix: hook on_load_fail and redirect the failed load to an inert
-- placeholder. Playlist position stays on the broken entry, playback is
-- paused. Good files still auto-advance normally.
--
-- Display, in order of preference:
--  1. If ~~home/fonts/uosc_icons.otf exists (shipped with uosc), draw a
--     large centered `broken_image` Material icon via an OSD overlay —
--     same colors/geometry as uosc's own idle indicator. Icon + filename only.
--  2. Otherwise, persistent OSD text (osd-msg1) with the filename.
-- The title is left as the plain filename; the icon alone marks it broken.
-- Good files still auto-advance normally.
--
-- Optional: drop an image at ~~home/broken.png and it will be used as the
-- placeholder source instead of the black lavfi color.

local utils = require("mp.utils")
local msg = require("mp.msg")

local PLACEHOLDER_SRC = "av://lavfi:color=c=black:s=1280x720:r=1"
local ICON_FONT_FILE = "~~home/fonts/uosc_icons.otf"
local ICON_FONT_NAME = "MaterialIconsRound-Regular"
local ICON_NAME = "broken_image"

local function expand(path)
    local ok, res = pcall(mp.command_native, { "expand-path", path })
    if ok and type(res) == "string" then return res end
    return nil
end

local function file_exists(path)
    local expanded = expand(path)
    if not expanded then return false end
    local info = utils.file_info(expanded)
    return info ~= nil and not info.is_dir
end

local has_icons = file_exists(ICON_FONT_FILE)
if has_icons then
    msg.info("stay-on-error: using uosc icon font for broken-file glyph")
else
    msg.info("stay-on-error: uosc icon font not found, falling back to text")
end

local function placeholder_for()
    if file_exists("~~home/broken.png") then
        return expand("~~home/broken.png"), true
    end
    return PLACEHOLDER_SRC, false
end

-- OSD overlay for the icon path. Created lazily so --no-config / vo=null
-- probes without OSD don't error.
local overlay = nil
local showing = false
local pending_failed = nil

local function basename(path)
    local name = tostring(path or "")
    name = name:gsub("\\", "/")
    return name:match("/([^/]*)$") or name
end

local function ass_escape(s)
    s = tostring(s or "")
    -- libass has no brace escaping; bracket-swap is the safe fallback.
    s = s:gsub("{", "("):gsub("}", ")")
    return s
end

-- Mirrors uosc's idle indicator: white (foreground ffffff) at 0.8 opacity.
-- Icon size = smaller side / 4, label below at icon / 4. Icon + filename only.
local function render_icon(failed)
    if not overlay then
        local ok, ov = pcall(mp.create_osd_overlay, "ass-events")
        if not ok or not ov then return end
        overlay = ov
    end
    local w, h = 1280, 720
    local ok_w, ow, oh = pcall(mp.get_osd_size)
    if ok_w and ow and oh and ow > 0 and oh > 0 then
        w, h = ow, oh
    end
    local icon_size = math.max(56, math.floor(math.min(w, h) / 4))
    local name_size = math.floor(icon_size / 4)
    overlay.res_x, overlay.res_y = w, h
    overlay.data = string.format(
        "{\\an5\\fn%s\\fs%d\\c&HFFFFFF&\\bord0\\alpha&H33&}%s{\\r\\fs%d\\c&HFFFFFF&\\bord0\\alpha&H33&}\\N%s",
        ICON_FONT_NAME, icon_size, ICON_NAME,
        name_size, ass_escape(basename(failed)))
    local ok, err = pcall(function() overlay:update() end)
    if not ok then
        msg.warn("stay-on-error: overlay update failed: " .. tostring(err))
    end
    showing = true
end

local function hide_icon()
    if overlay and showing then
        pcall(function() overlay:remove() end)
    end
    showing = false
end

mp.add_hook("on_load_fail", 50, function()
    local failed = mp.get_property("stream-open-filename", "")
    if failed == "" then
        failed = mp.get_property("path", "")
    end
    msg.warn("loading failed, staying on entry instead of skipping: " .. tostring(failed))
    pending_failed = failed

    local src, is_image = placeholder_for()
    mp.set_property("stream-open-filename", src)
    mp.set_property("file-local-options/pause", "yes")
    -- Plain filename as title (no BROKEN prefix); the icon marks it broken.
    mp.set_property("file-local-options/force-media-title", basename(failed))
    if is_image then
        mp.set_property("file-local-options/image-display-duration", "inf")
    end
    if not has_icons then
        -- Text fallback only when the icon font is unavailable.
        mp.set_property("file-local-options/osd-msg1",
            "BROKEN FILE — loading failed, stayed here instead of skipping:\n"
            .. tostring(failed)
            .. "\n\nNext/Prev (< >) to move manually.")
    else
        mp.set_property("file-local-options/osd-msg1", "")
    end
end)

mp.register_event("file-loaded", function()
    if pending_failed then
        if has_icons then
            render_icon(pending_failed)
        end
        pending_failed = nil
    end
end)

-- Never leak the icon (or text, which is file-local anyway) onto the next file.
mp.register_event("start-file", function()
    pending_failed = nil
    hide_icon()
end)
mp.register_event("end-file", function()
    pending_failed = nil
    hide_icon()
end)

-- Keep the icon centered on resize/window changes while shown.
mp.observe_property("osd-dimensions", "native", function()
    if showing and overlay then
        -- Title is the plain basename (see hook), reuse it for the label.
        render_icon(mp.get_property("media-title", ""))
    end
end)
