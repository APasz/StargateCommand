local constants = require("core.constants")
local config_schema = require("config.schema")
local log = require("core.log")
local main = require("main")
local update_client = require("services.update_client")

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

            return validation.value, path, nil
        end
    end

    return nil, nil, {
        error = "missing_config",
    }
end

---@return boolean
function startup.run()
    local config, loaded_path, load_error = startup.load_local_config()
    if config == nil then
        if loaded_path ~= nil then
            return fail("invalid config at " .. loaded_path, load_error.details or load_error)
        end

        return fail("missing config", {
            expected_paths = constants.DEFAULT_CONFIG_PATHS,
        })
    end

    local update_logger = log.new(
        "startup.update",
        config.logging ~= nil and config.logging.level or "info"
    )
    local update_result = update_client.preflight(config, update_logger)
    if not update_result.ok then
        return fail("startup update failed: " .. update_result.error, update_result.details)
    end

    if update_result.value.applied then
        return fail("update applied; reboot required", update_result.value)
    end

    local run_result = main.run(config)
    if not run_result.ok then
        return fail("application failed: " .. run_result.error, run_result.details)
    end

    return true
end

return startup
