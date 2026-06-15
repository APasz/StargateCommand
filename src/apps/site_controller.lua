local shared = require("apps.shared")
local site_controller = require("site.controller")

local app = {}

---@param config table
---@return SgcResult
function app.run(config)
    local logger = shared.logger("app.site_controller", config)
    shared.log_start(logger)
    return shared.as_result(site_controller.serve(config, logger))
end

return app
