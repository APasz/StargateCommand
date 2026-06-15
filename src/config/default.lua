local constants = require("core.constants")
local tablex = require("core.tablex")

local defaults = {}

---@param role SgcRole
---@return boolean
local function is_address_book_role(role)
    return role == "address_book" or role == "address_book_server"
end

---@param role SgcRole
---@return CcSide?
local function default_site_modem_side(role)
    if is_address_book_role(role) then
        return nil
    end

    return "bottom"
end

---@param role SgcRole
---@return CcSide?
local function default_intersite_modem_side(role)
    if role == "site_controller" or is_address_book_role(role) then
        return "right"
    end

    return nil
end

---@param role SgcRole
---@return SgcAddressBookMode
local function default_address_book_mode(role)
    if role == "gate_controller" or role == "bridge" or role == "update_client" then
        return "disabled"
    end

    if is_address_book_role(role) then
        return "server"
    end

    return "client"
end

---@param role SgcRole?
---@param overrides table?
---@return table
function defaults.for_role(role, overrides)
    local resolved_role = role or "site_controller"
    local bootstrap_address_book = is_address_book_role(resolved_role)
    local config = {
        schema = constants.CONFIG_SCHEMA_VERSION,
        site = "command",
        role = resolved_role,
        modems = {
            site = default_site_modem_side(resolved_role),
            peripheral = "top",
            intersite = default_intersite_modem_side(resolved_role),
        },
        address_book = {
            mode = default_address_book_mode(resolved_role),
            cache_path = constants.DEFAULT_ADDRESS_BOOK_CACHE_PATH,
            server_site = "command",
            server_path = constants.DEFAULT_ADDRESS_BOOK_SERVER_PATH,
            bootstrap_on_missing = bootstrap_address_book,
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
        dial_console = {
            monitor_text_scale = constants.DEFAULT_MONITOR_TEXT_SCALE,
        },
        alarm = {
            poll_interval_ms = 250,
            monitor_text_scale = constants.DEFAULT_ALARM_MONITOR_TEXT_SCALE,
            trigger_on_fault = true,
            speaker = {
                bindings = {
                    {
                        signal = "system_error",
                        pattern = "pattern_beta",
                    },
                    {
                        signal = "connection_incoming",
                        pattern = "pattern_alpha",
                    },
                },
            },
            outputs = {
                {
                    driver = "redstone",
                    side = "left",
                    signal = "connection_established",
                    active_high = true,
                },
                {
                    driver = "redstone",
                    side = "right",
                    signal = "system_error",
                    active_high = true,
                },
                {
                    driver = "bundled",
                    side = "back",
                    channels = {
                        orange = "connection_established",
                        magenta = {
                            signal = "system_error",
                            mode = "pulse",
                        },
                        blue = "wormhole_incoming",
                        green = "chevron_engaged",
                        red = "wormhole_outgoing",
                        lightBlue = "traveller_in",
                        brown = "traveller_out",
                        gray = "reset",
                    },
                },
            },
        },
    }

    local merged = tablex.deep_merge(config, overrides)
    if overrides ~= nil
        and type(overrides.alarm) == "table"
        and type(overrides.alarm.outputs) == "table"
    then
        merged.alarm.outputs = tablex.deep_copy(overrides.alarm.outputs)
    end
    if overrides ~= nil
        and type(overrides.alarm) == "table"
        and type(overrides.alarm.speaker) == "table"
        and type(overrides.alarm.speaker.bindings) == "table"
    then
        merged.alarm.speaker.bindings = tablex.deep_copy(overrides.alarm.speaker.bindings)
    end

    return merged
end

return defaults
