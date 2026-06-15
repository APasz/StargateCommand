local energy_controller = require("services.energy_controller")
local shared = require("apps.shared")

local app = {}

---@param config table
---@return SgcResult
function app.run(config)
    shared.log_start(shared.logger("app.energy_controller", config))
    return shared.as_result(energy_controller.start(config))
end

return app
