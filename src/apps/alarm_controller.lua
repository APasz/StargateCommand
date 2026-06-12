local alarm_controller = require("services.alarm_controller")
local shared = require("apps.shared")

local app = {}

---@param config table
---@return SgcResult
function app.run(config)
    shared.logger("app.alarm_controller", config):info("starting", {
        site = config.site,
    })
    return shared.as_result(alarm_controller.start(config))
end

return app

