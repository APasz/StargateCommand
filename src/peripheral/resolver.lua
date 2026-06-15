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
---@param remote_name string
---@return boolean
local function remote_matches_type(modem, remote_name, peripheral_type)
    if type(modem.hasTypeRemote) == "function" then
        local ok, has_type = pcall(modem.hasTypeRemote, remote_name, peripheral_type)
        if ok and has_type == true then
            return true
        end
    end

    if type(modem.getTypeRemote) == "function" then
        local ok, primary_type, secondary_type, tertiary_type = pcall(modem.getTypeRemote, remote_name)
        if ok and (primary_type == peripheral_type or secondary_type == peripheral_type or tertiary_type == peripheral_type) then
            return true
        end
    end

    return false
end

---@param modem table
---@param peripheral_type string
---@return string[]
local function find_remote_names(modem, peripheral_type)
    local remote_names = {}
    if type(modem.getNamesRemote) ~= "function" then
        return remote_names
    end

    for _, remote_name in ipairs(modem.getNamesRemote()) do
        if remote_matches_type(modem, remote_name, peripheral_type) then
            remote_names[#remote_names + 1] = remote_name
        end
    end

    return remote_names
end

---@param side string
---@param peripheral_type string
---@param local_matcher fun(candidate: table): boolean
---@return SgcResult
function resolver.resolve_all(side, peripheral_type, local_matcher)
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
        return result.ok({
            {
                peripheral = wrapped,
                id = side,
                remote = false,
            },
        })
    end

    if type(wrapped.callRemote) ~= "function" then
        return result.err("missing_" .. peripheral_type, {
            side = side,
        })
    end

    local remote_names = find_remote_names(wrapped, peripheral_type)
    if #remote_names == 0 then
        return result.err("missing_" .. peripheral_type, {
            side = side,
        })
    end

    local peripherals = {}
    for _, remote_name in ipairs(remote_names) do
        peripherals[#peripherals + 1] = {
            peripheral = wrap_remote_peripheral(wrapped, remote_name),
            id = remote_name,
            remote = true,
            modem_side = side,
        }
    end

    return result.ok(peripherals)
end

---@param side string
---@param peripheral_type string
---@param local_matcher fun(candidate: table): boolean
---@return SgcResult
function resolver.resolve(side, peripheral_type, local_matcher)
    local resolved = resolver.resolve_all(side, peripheral_type, local_matcher)
    if not resolved.ok then
        return resolved
    end

    local first = resolved.value[1]
    return result.ok(first.peripheral, {
        id = first.id,
        remote = first.remote,
        modem_side = first.modem_side,
    })
end

return resolver
