-- nightcore.lua: independent speed + pitch control.
--
-- Speed (nightcore effect: no pitch correction by default, so faster == sharper):
--   ] / [  : coarser step (5%)
--   } / {  : finer step (1%)
--
-- Pitch (rubberband R3 engine, duration unchanged, stacks on top of speed):
--   Ctrl+] / Ctrl+[  : coarser step (5%-equivalent  = ~0.85 st)
--   Ctrl+} / Ctrl+{  : finer step (1%-equivalent    = ~0.17 st)
--
--   p  : reset speed AND pitch
--
-- Hold any stepper to auto-repeat (tunable in script-opts/nightcore.conf:
-- hold_delay=0.5, hold_rate=5).
-- Both steppers share the same lattice logic: above 1x they snap to
-- 1 + n*d (so 1.03 + ] -> 1.05), below 1x they snap to the reciprocal
-- lattice 1/(1 + m*d) (so pitch semitones mirror speed: -0.85 st, -1.65 st, ...).

local EPS = 1e-7
local PITCH_LABEL = "nightcore_pitch" -- inserted as @nightcore_pitch:rubberband=...

-- Pitch state: linear factor, 1.0 = unchanged.
-- Semitones are derived: st = 12 * log2(factor).
local pitch_factor = 1.0

local function next_up(s, d)
    if s >= 1 then
        local n = math.ceil((s - 1) / d)
        local cand = 1 + n * d
        if math.abs(cand - s) < EPS then
            n = n + 1
            cand = 1 + n * d
        end
        return cand
    else
        local m_calc = (1 / s - 1) / d
        local m = math.floor(m_calc)
        local cand = 1 / (1 + m * d)
        if math.abs(cand - s) < EPS then
            m = m - 1
            if m < 0 then m = 0 end
            cand = 1 / (1 + m * d)
        end
        return cand
    end
end

local function next_down(s, d)
    if s >= 1 then
        local n = math.floor((s - 1) / d)
        local cand = 1 + n * d
        if math.abs(cand - s) < EPS then
            n = n - 1
            cand = 1 + n * d
        end
        if n < 0 then
            cand = 1 / (1 + d)
        end
        return cand
    else
        local m_calc = (1 / s - 1) / d
        local m = math.ceil(m_calc)
        local cand = 1 / (1 + m * d)
        if math.abs(cand - s) < EPS then
            m = m + 1
            cand = 1 / (1 + m * d)
        end
        return cand
    end
end

local function factor_to_semitones(f)
    return 12 * math.log(f) / math.log(2)
end

local function fmt_scale(f)
    return string.format("%.6f", f)
end

local function pitch_spec(scale)
    return "@" .. PITCH_LABEL .. ":rubberband=engine=finer:pitch-scale=" .. fmt_scale(scale)
end

local function has_pitch_filter()
    local af = mp.get_property("af", "")
    return af:find("@" .. PITCH_LABEL, 1, true) ~= nil
end

local function af_without_pitch(af)
    local s = "," .. af .. ","
    s = s:gsub(",@" .. PITCH_LABEL .. ":[^,]*,", ",")
    if s == "," then
        return ""
    end
    return s:sub(2, -2)
end

local function apply_pitch()
    if pitch_factor == 1 then
        -- back to neutral: drop the filter entirely so it costs no CPU
        if has_pitch_filter() then
            mp.set_property("af", af_without_pitch(mp.get_property("af", "")))
        end
        return
    end
    if has_pitch_filter() then
        -- gapless runtime update (label addressed WITHOUT the @)
        local ok = mp.commandv("af-command", PITCH_LABEL, "set-pitch", fmt_scale(pitch_factor))
        if not ok then
            -- chain was clobbered from outside: rebuild our entry
            mp.set_property("af", af_without_pitch(mp.get_property("af", "")))
            mp.commandv("af", "add", pitch_spec(pitch_factor))
        end
    else
        mp.commandv("af", "add", pitch_spec(pitch_factor))
    end
end

local function show_all()
    local s = mp.get_property_number("speed", 1)
    local msg
    if s >= 1 then
        msg = string.format("Speed: %.2fx", s)
    else
        msg = string.format("Speed: %.3fx (%.2fx)", s, 1 / s)
    end
    if pitch_factor == 1 then
        msg = msg .. " | Pitch: +0.00 st"
    else
        msg = msg .. string.format(" | Pitch: %+.2f st (x%.4f)",
            factor_to_semitones(pitch_factor), pitch_factor)
    end
    mp.osd_message(msg, 1.5)
end

local function speed_step(d, dir)
    local s = mp.get_property_number("speed", 1)
    local new_s
    if dir > 0 then
        new_s = next_up(s, d)
    else
        new_s = next_down(s, d)
    end
    mp.set_property_number("speed", new_s)
    show_all()
end

local function pitch_step(d, dir)
    if dir > 0 then
        pitch_factor = next_up(pitch_factor, d)
    else
        pitch_factor = next_down(pitch_factor, d)
    end
    apply_pitch()
    show_all()
end

local options = require("mp.options")
local opts = {
    -- seconds to hold before auto-repeat kicks in
    hold_delay = 0.5,
    -- repeats per second once held
    hold_rate = 5,
}
options.read_options(opts, "nightcore")

local HOLD_DELAY = tonumber(opts.hold_delay) or 0.5
local hold_rate = tonumber(opts.hold_rate) or 5
if HOLD_DELAY < 0 then HOLD_DELAY = 0 end
if not (hold_rate > 0) then hold_rate = 5 end
local HOLD_INTERVAL = 1 / hold_rate -- repeat interval once held

-- Press-and-hold wrapper: single step on press, then auto-repeat while held.
-- Uses complex binding (down/up events) with our own timers so the 1s delay
-- applies only to these keys and doesn't affect global input-ar-delay.
local function bind_hold(key, name, step_fn)
    local delay_timer = nil
    local repeat_timer = nil
    local function stop()
        if delay_timer then
            delay_timer:kill()
            delay_timer = nil
        end
        if repeat_timer then
            repeat_timer:kill()
            repeat_timer = nil
        end
    end
    mp.add_key_binding(key, name, function(event)
        if event.event == "down" then
            step_fn()
            stop()
            delay_timer = mp.add_timeout(HOLD_DELAY, function()
                delay_timer = nil
                repeat_timer = mp.add_periodic_timer(HOLD_INTERVAL, step_fn)
            end)
        elseif event.event == "press" then
            -- fallback: invoked via script-message, menu, etc. (no down/up)
            step_fn()
        elseif event.event == "up" or event.event == "cancel" then
            stop()
        end
        -- NOTE: deliberately ignoring "repeat" events; our own timer handles it
    end, { complex = true, repeatable = true })
end

bind_hold("]", "speed-up-5", function() speed_step(0.05, 1) end)
bind_hold("[", "speed-down-5", function() speed_step(0.05, -1) end)
bind_hold("}", "speed-up-1", function() speed_step(0.01, 1) end)
bind_hold("{", "speed-down-1", function() speed_step(0.01, -1) end)

bind_hold("Ctrl+]", "pitch-up-5", function() pitch_step(0.05, 1) end)
bind_hold("Ctrl+[", "pitch-down-5", function() pitch_step(0.05, -1) end)
bind_hold("Ctrl+}", "pitch-up-1", function() pitch_step(0.01, 1) end)
bind_hold("Ctrl+{", "pitch-down-1", function() pitch_step(0.01, -1) end)

mp.add_key_binding("p", "nightcore-reset", function()
    mp.set_property_number("speed", 1)
    pitch_factor = 1.0
    apply_pitch()
    show_all()
end)

-- re-attach the pitch filter if something (e.g. a profile restore) wiped the
-- filter chain while a pitch shift was active; speed is mpv-owned and persists
mp.register_event("file-loaded", function()
    if pitch_factor ~= 1 and not has_pitch_filter() then
        apply_pitch()
    end
end)
