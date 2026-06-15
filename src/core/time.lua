local time = {}

---@return integer
function time.now_ms()
    if os ~= nil and type(os.epoch) == "function" then
        local ok, value = pcall(os.epoch, "utc")
        if ok and type(value) == "number" then
            return value
        end
    end

    if os ~= nil and type(os.time) == "function" then
        local ok, value = pcall(os.time)
        if ok and type(value) == "number" then
            return value * 1000
        end
    end

    return 0
end

---@return integer
function time.now_seconds()
    return math.floor(time.now_ms() / 1000)
end

---@return string
function time.now_hms()
    local now_ms = time.now_ms()
    local total_seconds = math.floor(now_ms / 1000)
    local seconds_in_day = 24 * 60 * 60
    local day_seconds = total_seconds % seconds_in_day
    local hours = math.floor(day_seconds / 3600)
    local minutes = math.floor((day_seconds % 3600) / 60)
    local seconds = day_seconds % 60
    return string.format("%02d:%02d:%02d", hours, minutes, seconds)
end

return time
