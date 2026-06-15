local result = require("core.result")

local resolver = {}

---@param modem table
---@param remote_name string
---@return table
local function wrap_remote_peripheral(modem, remote_name)
    local wrapped = {}

    return setmetatable(wrapped, {
        __index = function(_, method_name)
            return function(...)
                return modem.callRemote(remote_name, method_name, ...)
            end
        end,
    })
end

---@param modem table
---@param peripheral_type string
---@return string?
local function find_remote_name(modem, peripheral_type)
    if type(modem.getNamesRemote) ~= "function" then
        return nil
    end

    for _, remote_name in ipairs(modem.getNamesRemote()) do
        if type(modem.hasTypeRemote) == "function" then
            local ok, has_type = pcall(modem.hasTypeRemote, remote_name, peripheral_type)
            if ok and has_type == true then
                return remote_name
            end
        end

        if type(modem.getTypeRemote) == "function" then
            local ok, primary_type, secondary_type, tertiary_type = pcall(modem.getTypeRemote, remote_name)
            if ok and (primary_type == peripheral_type or secondary_type == peripheral_type or tertiary_type == peripheral_type) then
                return remote_name
            end
        end
    end

    return nil
end

---@param side string
---@param peripheral_type string
---@param local_matcher fun(candidate: table): boolean
---@return SgcResult
function resolver.resolve(side, peripheral_type, local_matcher)
    if peripheral == nil or type(peripheral.wrap) ~= "function" then
        return result.err("peripheral_api_unavailable")
    end

    local wrapped = peripheral.wrap(side)
    if wrapped == nil then
        return result.err("missing_" .. peripheral_type, {
            side = side,
        })
    end

    if local_matcher(wrapped) then
        return result.ok(wrapped, {
            id = side,
            remote = false,
        })
    end

    local remote_name = find_remote_name(wrapped, peripheral_type)
    if remote_name ~= nil and type(wrapped.callRemote) == "function" then
        return result.ok(wrap_remote_peripheral(wrapped, remote_name), {
            id = remote_name,
            remote = true,
            modem_side = side,
        })
    end

    return result.err("missing_" .. peripheral_type, {
        side = side,
    })
end

return resolver
