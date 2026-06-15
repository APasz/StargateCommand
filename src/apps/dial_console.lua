local dial_console = require("services.dial_console")
local shared = require("apps.shared")

local app = {}

---@param config table
---@return SgcResult
function app.run(config)
    local logger = shared.logger("app.dial_console", config)
    shared.log_start(logger)

    return shared.as_result(dial_console.start(config, logger))
end

return app
