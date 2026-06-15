local address_book_client = require("address_book.client")
local shared = require("apps.shared")

local app = {}

---@param config table
---@return SgcResult
function app.run(config)
    shared.log_start(shared.logger("app.display", config))

    local cached = address_book_client.start(config)
    return shared.as_result({
        role = config.role,
        address_book = cached.ok and cached.value or nil,
        note = "Display rendering is scaffolded only.",
    })
end

return app
