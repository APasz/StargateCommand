local envelope = require("net.envelope")

local discovery = {}

---@param config table
---@param advertised table?
---@return SgcResult
function discovery.create_hello(config, advertised)
    local payload = {
        computer_id = os and os.getComputerID and os.getComputerID() or nil,
        services = advertised and advertised.services or { config.role },
        capabilities = advertised and advertised.capabilities or {},
    }

    return envelope.new("hello", config.site, config.role, payload)
end

return discovery

