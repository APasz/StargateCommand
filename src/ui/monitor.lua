local monitor = {}

---@param side string
---@param lines string[]
---@return SgcResult
function monitor.render(side, lines)
    if peripheral == nil or type(peripheral.wrap) ~= "function" then
        return {
            ok = false,
            error = "peripheral_api_unavailable",
        }
    end

    local wrapped = peripheral.wrap(side)
    if wrapped == nil then
        return {
            ok = false,
            error = "missing_monitor",
            details = { side = side },
        }
    end

    if type(wrapped.clear) == "function" then
        wrapped.clear()
        wrapped.setCursorPos(1, 1)
    end

    for _, line in ipairs(lines) do
        wrapped.write(line)
        if type(wrapped.getCursorPos) == "function" and type(wrapped.setCursorPos) == "function" then
            local _, y = wrapped.getCursorPos()
            wrapped.setCursorPos(1, y + 1)
        end
    end

    return {
        ok = true,
        value = true,
    }
end

return monitor

