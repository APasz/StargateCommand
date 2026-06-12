local iris_controller = require("services.iris_controller")
local shared = require("apps.shared")

local app = {}

---@param config table
---@return SgcResult
function app.run(config)
    shared.logger("app.iris_controller", config):info("starting", {
        site = config.site,
    })
    return shared.as_result(iris_controller.start(config))
end

return app

