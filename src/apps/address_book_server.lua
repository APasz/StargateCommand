local address_book_server = require("address_book.server")
local shared = require("apps.shared")

local app = {}

---@param config table
---@return SgcResult
function app.run(config)
    local logger = shared.logger("app.address_book_server", config)
    shared.log_start(logger)
    return shared.as_result(address_book_server.serve(config, logger))
end

return app
