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

return time

