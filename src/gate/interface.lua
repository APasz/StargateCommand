local capabilities = require("gate.capabilities")
local constants = require("core.constants")
local result = require("core.result")

local gate_interface = {}

---@param interface_type string
---@return string?
local function find_side(interface_type)
    if peripheral == nil or type(peripheral.getNames) ~= "function" or type(peripheral.getType) ~= "function" then
        return nil
    end

    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == interface_type then
            return side
        end
    end

    return nil
end

---@param instance table
---@param capability_key string
---@param method_name string
---@param ... any
---@return SgcResult
local function call_supported(instance, capability_key, method_name, ...)
    if instance.capabilities[capability_key] ~= true then
        return result.err("unsupported_method", {
            side = instance.side,
            interface_type = instance.interface_type,
            capability = capability_key,
            method = method_name,
        })
    end

    if peripheral == nil or type(peripheral.call) ~= "function" then
        return result.err("peripheral_api_unavailable")
    end

    local ok, value = pcall(peripheral.call, instance.side, method_name, ...)
    if not ok then
        return result.err("peripheral_call_failed", {
            side = instance.side,
            interface_type = instance.interface_type,
            method = method_name,
            cause = tostring(value),
        })
    end

    return result.ok(value)
end

---@return SgcResult
function gate_interface.discover()
    if peripheral == nil then
        return result.err("peripheral_api_unavailable")
    end

    for _, interface_type in ipairs(constants.INTERFACE_PRIORITY) do
        local side = find_side(interface_type)
        if side ~= nil then
            return result.ok({
                side = side,
                interface_type = interface_type,
                capabilities = capabilities.for_type(interface_type),
            })
        end
    end

    return result.err("missing_interface", {
        wanted = constants.INTERFACE_PRIORITY,
    })
end

---@param address integer[]?
---@return string
function gate_interface.address_to_string(address)
    if type(address) ~= "table" or #address == 0 or #address > 8 then
        return "-"
    end

    return "-" .. table.concat(address, "-") .. "-"
end

---@param instance table
---@return SgcResult
function gate_interface.get_energy(instance)
    return call_supported(instance, "energy", "getEnergy")
end

---@param instance table
---@return SgcResult
function gate_interface.get_capacity(instance)
    return call_supported(instance, "energy", "getEnergyCapacity")
end

---@param instance table
---@return SgcResult
function gate_interface.get_local_address(instance)
    return call_supported(instance, "local_address", "getLocalAddress")
end

---@param instance table
---@return SgcResult
function gate_interface.get_dialed_address(instance)
    return call_supported(instance, "dialed_address", "getDialedAddress")
end

---@param instance table
---@return SgcResult
function gate_interface.get_connected_address(instance)
    return call_supported(instance, "connected_address", "getConnectedAddress")
end

---@param instance table
---@return SgcResult
function gate_interface.is_connected(instance)
    return call_supported(instance, "state", "isStargateConnected")
end

---@param instance table
---@return SgcResult
function gate_interface.is_open(instance)
    return call_supported(instance, "state", "isWormholeOpen")
end

---@param instance table
---@return SgcResult
function gate_interface.is_dialing_out(instance)
    return call_supported(instance, "state", "isStargateDialingOut")
end

---@param instance table
---@return SgcResult
function gate_interface.disconnect(instance)
    return call_supported(instance, "disconnect", "disconnectStargate")
end

---@param instance table
---@return SgcResult
function gate_interface.get_iris(instance)
    return call_supported(instance, "iris", "getIris")
end

---@param instance table
---@return SgcResult
function gate_interface.open_iris(instance)
    return call_supported(instance, "iris", "openIris")
end

---@param instance table
---@return SgcResult
function gate_interface.close_iris(instance)
    return call_supported(instance, "iris", "closeIris")
end

---@param instance table
---@return SgcResult
function gate_interface.stop_iris(instance)
    return call_supported(instance, "iris", "stopIris")
end

---@param instance table
---@return SgcResult
function gate_interface.get_iris_progress(instance)
    return call_supported(instance, "iris", "getIrisProgress")
end

---@param instance table
---@return SgcResult
function gate_interface.get_iris_progress_percent(instance)
    return call_supported(instance, "iris", "getIrisProgressPercentage")
end

return gate_interface

