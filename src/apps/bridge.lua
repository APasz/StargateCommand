local bridge = require("services.bridge")
local shared = require("apps.shared")

local app = {}

---@param config table
---@return SgcResult
function app.run(config)
    shared.logger("app.bridge", config):info("starting", {
        site = config.site,
    })
    return shared.as_result(bridge.start(config))
end

return app

