local EPS = 1e-7

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

local function show_speed(s)
    local msg
    if s >= 1 then
        msg = string.format("Speed: %.2fx", s)
    else
        local recip = 1 / s
        msg = string.format("Speed: %.3fx (%.2fx)", s, recip)
    end
    mp.osd_message(msg, 1.5)
end

mp.add_key_binding("]", "speed-up-5", function()
    local s = mp.get_property_number("speed")
    local new_s = next_up(s, 0.05)
    mp.set_property_number("speed", new_s)
    show_speed(new_s)
end)

mp.add_key_binding("[", "speed-down-5", function()
    local s = mp.get_property_number("speed")
    local new_s = next_down(s, 0.05)
    mp.set_property_number("speed", new_s)
    show_speed(new_s)
end)

mp.add_key_binding("}", "speed-up-1", function()
    local s = mp.get_property_number("speed")
    local new_s = next_up(s, 0.01)
    mp.set_property_number("speed", new_s)
    show_speed(new_s)
end)

mp.add_key_binding("{", "speed-down-1", function()
    local s = mp.get_property_number("speed")
    local new_s = next_down(s, 0.01)
    mp.set_property_number("speed", new_s)
    show_speed(new_s)
end)

mp.add_key_binding("p", "speed-reset", function()
    mp.set_property_number("speed", 1)
    show_speed(1)
end)
