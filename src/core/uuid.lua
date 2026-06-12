local time = require("core.time")

local uuid = {}
local counter = 0

---@return integer
local function get_computer_id()
    if os ~= nil and type(os.getComputerID) == "function" then
        local ok, value = pcall(os.getComputerID)
        if ok and type(value) == "number" then
            return value
        end
    end

    return 0
end

---@param prefix string?
---@return string
function uuid.new(prefix)
    counter = counter + 1
    local label = prefix or "sgc"
    local random_value = math.random(100000, 999999)

    return string.format(
        "%s-%d-%d-%d-%d",
        label,
        time.now_ms(),
        get_computer_id(),
        counter,
        random_value
    )
end

return uuid

