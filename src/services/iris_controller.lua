local gate_interface = require("gate.interface")
local result = require("core.result")

local iris_controller = {}

---@param instance table
---@return SgcResult
function iris_controller.read(instance)
    local identifier = gate_interface.get_iris(instance)
    local progress = gate_interface.get_iris_progress(instance)
    local percent = gate_interface.get_iris_progress_percent(instance)

    return result.ok({
        supported = instance.capabilities.iris == true,
        identifier = identifier.ok and identifier.value or nil,
        installed = identifier.ok and identifier.value ~= nil or nil,
        progress = progress.ok and progress.value or nil,
        progress_percent = percent.ok and percent.value or nil,
    })
end

---@param _config table
---@return SgcResult
function iris_controller.start(_config)
    local discovered = gate_interface.discover()
    if not discovered.ok then
        return discovered
    end

    return iris_controller.read(discovered.value)
end

return iris_controller

