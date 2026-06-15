local shared = require("apps.shared")
local update_client = require("services.update_client")

local app = {}

---@param config table
---@return SgcResult
function app.run(config)
    local logger = shared.logger("app.update_client", config)
    shared.log_start(logger)

    local sync_result = update_client.start(config, logger)
    if sync_result.ok then
        logger:info("completed", sync_result.value)
    end

    return shared.as_result(sync_result)
end

return app
