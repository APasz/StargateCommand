local constants = require("core.constants")
local config_defaults = require("config.default")
local config_schema = require("config.schema")
local host_lifecycle = require("lifecycle.host")
local log = require("core.log")
local log_messages = require("core.log_messages")
local main = require("main")
local update_client = require("services.update_client")
local update_store = require("update.store")
local update_version = require("update.version")

local startup = {}

---@param path string
---@return boolean
local function path_exists(path)
    if fs ~= nil and type(fs.exists) == "function" then
        local ok, exists = pcall(fs.exists, path)
        return ok and exists == true
    end

    local handle = io.open(path, "r")
    if handle ~= nil then
        handle:close()
        return true
    end

    return false
end

---@param message string
---@param details table?
---@return boolean
local function fail(message, details)
    if term ~= nil and colors ~= nil and type(term.setTextColor) == "function" then
        pcall(term.setTextColor, colors.red)
    end

    if type(printError) == "function" then
        printError("[sgc] " .. message)
    else
        print("[sgc] " .. message)
    end

    if details ~= nil then
        if textutils ~= nil and type(textutils.serialize) == "function" then
            print(textutils.serialize(details))
        else
            print(tostring(details))
        end
    end

    if term ~= nil and colors ~= nil and type(term.setTextColor) == "function" then
        pcall(term.setTextColor, colors.white)
    end

    return false
end

---@return boolean
local function disable_motd()
    if settings == nil or type(settings.set) ~= "function" then
        return true
    end

    local set_ok, set_error = pcall(settings.set, "motd.enable", false)
    if not set_ok then
        return fail("failed to disable motd", {
            cause = tostring(set_error),
        })
    end

    if type(settings.save) == "function" then
        local save_ok, save_error = pcall(settings.save)
        if not save_ok then
            return fail("failed to save settings", {
                cause = tostring(save_error),
            })
        end
    end

    return true
end

---@param path string
---@return table?, any
local function load_config_file(path)
    local ok, loaded = pcall(dofile, path)
    if not ok then
        return nil, loaded
    end

    return loaded, nil
end

---@param paths string[]?
---@return table?, string?, any
function startup.load_local_config(paths)
    for _, path in ipairs(paths or constants.DEFAULT_CONFIG_PATHS) do
        if path_exists(path) then
            local loaded, load_error = load_config_file(path)
            if load_error ~= nil then
                return nil, path, {
                    error = "config_load_failed",
                    cause = tostring(load_error),
                }
            end

            local validation = config_schema.validate(loaded)
            if not validation.ok then
                return nil, path, validation
            end

            local normalized = config_defaults.for_role(validation.value.role, validation.value)
            local normalized_validation = config_schema.validate(normalized)
            if not normalized_validation.ok then
                return nil, path, normalized_validation
            end

            return normalized_validation.value, path, nil
        end
    end

    return nil, nil, {
        error = "missing_config",
    }
end

---@param config table
---@return table?
local function load_installed_version_fields(config)
    local state_path = constants.DEFAULT_UPDATE_STATE_PATH
    if config.update ~= nil and type(config.update.state_path) == "string" and config.update.state_path ~= "" then
        state_path = config.update.state_path
    end

    local loaded_state = update_store.load_optional(state_path)
    if not loaded_state.ok or loaded_state.value == nil then
        return nil
    end

    local state = loaded_state.value
    local fields = {
        channel = state.channel,
        revision = state.revision,
        version = update_version.resolve_display_version(
            state.channel,
            state.revision,
            state.display_version
        ),
    }

    return fields
end

---@param config table
---@return string
local function build_computer_label(config)
    return string.format("%s.%s", config.site, config.role)
end

---@return string?
local function get_computer_label()
    if type(os) == "table" and type(os.getComputerLabel) == "function" then
        local ok, label = pcall(os.getComputerLabel)
        if ok and type(label) == "string" and label ~= "" then
            return label
        end
    end

    return nil
end

---@param label string
---@return boolean, table?
local function set_computer_label(label)
    if type(os) == "table" and type(os.setComputerLabel) == "function" then
        local ok, set_error = pcall(os.setComputerLabel, label)
        if not ok then
            return false, {
                api = "os.setComputerLabel",
                cause = tostring(set_error),
                label = label,
            }
        end

        return true, nil
    end

    return false, {
        api = "os.setComputerLabel",
        cause = "missing_api",
        label = label,
    }
end

---@param config table
---@return boolean, table?
local function sync_computer_label(config)
    local desired_label = build_computer_label(config)
    if get_computer_label() == desired_label then
        return true, nil
    end

    return set_computer_label(desired_label)
end

---@return boolean
function startup.run()
    if not disable_motd() then
        return false
    end

    local config, loaded_path, load_error = startup.load_local_config()
    if config == nil then
        if loaded_path ~= nil then
            return fail("invalid config at " .. loaded_path, load_error.details or load_error)
        end

        return fail("missing config", {
            expected_paths = constants.DEFAULT_CONFIG_PATHS,
        })
    end

    local label_synced, label_error = sync_computer_label(config)
    if not label_synced then
        return fail("failed to set computer label", label_error)
    end

    local update_logger = log.new(
        "startup.update",
        config.logging ~= nil and config.logging.level or "info"
    )
    local cleared_intent = host_lifecycle.consume_pending_intent(config)
    if not cleared_intent.ok then
        return fail("failed to clear pending lifecycle intent", cleared_intent.details)
    end

    local update_result = update_client.preflight(config, update_logger)
    if not update_result.ok then
        return fail("startup update failed: " .. update_result.error, update_result.details)
    end

    if update_result.value.applied then
        return fail("update applied; reboot required", update_result.value)
    end

    local startup_logger = log.new(
        "startup",
        config.logging ~= nil and config.logging.level or "info"
    )
    local startup_fields = {
        role = config.role,
        site = config.site,
    }
    local installed_version_fields = load_installed_version_fields(config)
    if installed_version_fields ~= nil then
        startup_fields.channel = installed_version_fields.channel
        startup_fields.revision = installed_version_fields.revision
        startup_fields.version = installed_version_fields.version
    end
    startup_logger:info(log_messages.startup(startup_fields.version, config.site))

    local run_result = main.run(config)
    if not run_result.ok then
        return fail("application failed: " .. run_result.error, run_result.details)
    end

    return true
end

return startup
