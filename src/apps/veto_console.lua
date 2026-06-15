local shared = require("apps.shared")

local app = {}

---@param config table
---@return SgcResult
function app.run(config)
    shared.log_start(shared.logger("app.veto_console", config))
    return shared.as_result({
        role = config.role,
        can_initiate = false,
        note = "Veto workflow is scaffolded only.",
    })
end

return app
