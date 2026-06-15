local alarm_controller = require("services.alarm_controller")
local shared = require("apps.shared")

local app = {}

---@param config table
---@return SgcResult
function app.run(config)
    local logger = shared.logger("app.alarm_controller", config)
    shared.log_start(logger)
    return shared.as_result(alarm_controller.start(config, logger))
end

return app
