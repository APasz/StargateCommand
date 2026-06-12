local tablex = require("core.tablex")

local capabilities = {}

local CAPABILITY_MAP = {
    basic_interface = {
        energy = true,
        local_address = false,
        dialed_address = false,
        connected_address = false,
        state = true,
        disconnect = true,
        iris = true,
    },
    crystal_interface = {
        energy = true,
        local_address = false,
        dialed_address = true,
        connected_address = false,
        state = true,
        disconnect = true,
        iris = true,
    },
    advanced_crystal_interface = {
        energy = true,
        local_address = true,
        dialed_address = true,
        connected_address = true,
        state = true,
        disconnect = true,
        iris = true,
    },
}

---@param interface_type string
---@return table
function capabilities.for_type(interface_type)
    return tablex.deep_copy(CAPABILITY_MAP[interface_type] or {})
end

return capabilities

