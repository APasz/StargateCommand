local iris_controller = require("services.iris_controller")
local shared = require("apps.shared")

local app = {}

---@param config table
---@return SgcResult
function app.run(config)
    shared.log_start(shared.logger("app.iris_controller", config))
    return shared.as_result(iris_controller.start(config))
end

return app
