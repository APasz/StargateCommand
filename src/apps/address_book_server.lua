local address_book_server = require("address_book.server")
local shared = require("apps.shared")

local app = {}

---@param config table
---@return SgcResult
function app.run(config)
    shared.logger("app.address_book_server", config):info("starting", {
        site = config.site,
    })
    return shared.as_result(address_book_server.start(config))
end

return app

