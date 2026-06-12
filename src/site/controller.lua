local address_book_client = require("address_book.client")
local discovery = require("net.discovery")
local result = require("core.result")
local site_state = require("site.state")
local transport = require("net.rednet_transport")

local controller = {}

---@param attempt SgcResult
---@param warnings table[]
local function record_warning(attempt, warnings)
    if attempt.ok then
        return
    end

    warnings[#warnings + 1] = {
        error = attempt.error,
        details = attempt.details,
    }
end

---@param config table
---@return SgcResult
function controller.start(config)
    local state = site_state.new(config)
    local warnings = {}
    local opened_modems = {}

    if config.modems.site ~= nil then
        local opened = transport.open(config.modems.site)
        if opened.ok then
            state.modems.site = true
            opened_modems[#opened_modems + 1] = config.modems.site
        else
            record_warning(opened, warnings)
        end
    end

    if config.role == "site_controller" and config.modems.intersite ~= nil then
        local opened = transport.open(config.modems.intersite)
        if opened.ok then
            state.modems.intersite = true
            opened_modems[#opened_modems + 1] = config.modems.intersite
        else
            record_warning(opened, warnings)
        end
    end

    local hello = discovery.create_hello(config, {
        services = { config.role },
        capabilities = {
            wireless = config.modems.intersite ~= nil,
        },
    })

    if not hello.ok then
        return hello
    end

    local address_book_state = address_book_client.start(config)
    record_warning(address_book_state, warnings)

    return result.ok({
        state = state,
        opened_modems = opened_modems,
        hello = hello.value,
        address_book = address_book_state.ok and address_book_state.value or nil,
        warnings = warnings,
    })
end

return controller

