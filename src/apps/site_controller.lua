local shared = require("apps.shared")
local site_controller = require("site.controller")

local app = {}

---@param config table
---@return SgcResult
function app.run(config)
    shared.logger("app.site_controller", config):info("starting", {
        site = config.site,
    })
    return shared.as_result(site_controller.start(config))
end

return app

