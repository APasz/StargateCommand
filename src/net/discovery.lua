local constants = require("core.constants")
local envelope = require("net.envelope")
local protocols = require("net.protocols")
local result = require("core.result")
local transport = require("net.rednet_transport")
local validate = require("core.validate")

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

---@param payload any
---@return SgcResult
function discovery.validate_payload(payload)
    local errors = {}
    if not validate.expect_table(errors, "payload", payload) then
        return validate.result(errors)
    end

    if payload.computer_id ~= nil then
        validate.expect_integer(errors, "payload.computer_id", payload.computer_id)
    end

    if payload.services ~= nil then
        if validate.expect_string_array(errors, "payload.services", payload.services) then
            for index, role in ipairs(payload.services) do
                if constants.ROLE_SET[role] ~= true then
                    validate.push_error(errors, "payload.services[" .. index .. "]", "unsupported role")
                end
            end
        end
    end

    if payload.capabilities ~= nil then
        validate.expect_table(errors, "payload.capabilities", payload.capabilities)
    end

    local validation = validate.result(errors)
    if not validation.ok then
        return validation
    end

    return result.ok(payload)
end

---@param config table
---@param advertised table?
---@return SgcResult
function discovery.announce(config, advertised)
    local built = discovery.create_hello(config, advertised)
    if not built.ok then
        return built
    end

    return transport.broadcast(protocols.for_type(built.value.type), built.value)
end

return discovery
