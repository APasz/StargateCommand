local gate_controller = require("gate.controller")
local shared = require("apps.shared")

local app = {}

---@param config table
---@return SgcResult
function app.run(config)
    shared.logger("app.gate_controller", config):info("starting", {
        site = config.site,
    })
    return shared.as_result(gate_controller.start(config))
end

return app

