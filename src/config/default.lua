local constants = require("core.constants")
local tablex = require("core.tablex")

local defaults = {}

---@param role SgcRole?
---@param overrides table?
---@return table
function defaults.for_role(role, overrides)
    local config = {
        schema = constants.CONFIG_SCHEMA_VERSION,
        site = "command",
        role = role or "site_controller",
        modems = {
            site = "bottom",
            peripheral = "top",
            intersite = "right",
        },
        address_book = {
            mode = "client",
            cache_path = constants.DEFAULT_ADDRESS_BOOK_CACHE_PATH,
            server_site = "command",
            server_path = constants.DEFAULT_ADDRESS_BOOK_SERVER_PATH,
        },
        security = {
            allowlist_enabled = false,
            allowed_computer_ids = {},
            shared_secret = nil,
        },
        update = {
            mode = constants.DEFAULT_UPDATE_MODE,
            base_url = constants.DEFAULT_UPDATE_BASE_URL,
            channel = constants.DEFAULT_UPDATE_CHANNEL,
            state_path = constants.DEFAULT_UPDATE_STATE_PATH,
            temp_dir = constants.DEFAULT_UPDATE_TEMP_DIR,
            auto_reboot = false,
        },
        logging = {
            level = "info",
        },
    }

    return tablex.deep_merge(config, overrides)
end

return defaults
