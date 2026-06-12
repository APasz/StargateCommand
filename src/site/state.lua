local time = require("core.time")

local site_state = {}

---@param config table
---@return table
function site_state.new(config)
    return {
        site = config.site,
        role = config.role,
        started_at = time.now_ms(),
        modems = {
            site = false,
            intersite = false,
        },
    }
end

return site_state

