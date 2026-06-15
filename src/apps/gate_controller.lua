local gate_controller = require("gate.controller")
local shared = require("apps.shared")

local app = {}

---@param config table
---@return SgcResult
function app.run(config)
    local logger = shared.logger("app.gate_controller", config)
    shared.log_start(logger)
    return shared.as_result(gate_controller.serve(config, logger))
end

return app
