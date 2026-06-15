local bridge = require("services.bridge")
local shared = require("apps.shared")

local app = {}

---@param config table
---@return SgcResult
function app.run(config)
    shared.log_start(shared.logger("app.bridge", config))
    return shared.as_result(bridge.start(config))
end

return app
