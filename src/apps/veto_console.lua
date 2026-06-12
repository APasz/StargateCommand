local shared = require("apps.shared")

local app = {}

---@param config table
---@return SgcResult
function app.run(config)
    shared.logger("app.veto_console", config):info("starting", {
        site = config.site,
    })
    return shared.as_result({
        role = config.role,
        can_initiate = false,
        note = "Veto workflow is scaffolded only.",
    })
end

return app

