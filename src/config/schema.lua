local constants = require("core.constants")
local result = require("core.result")
local validate = require("core.validate")

local schema = {}

local VALID_ADDRESS_BOOK_MODES = {
    client = true,
    server = true,
    disabled = true,
}

local VALID_LOG_LEVELS = {
    debug = true,
    info = true,
    warn = true,
    error = true,
}

local VALID_UPDATE_MODES = {
    disabled = true,
    notify = true,
    apply = true,
}

---@param config table
---@return SgcResult
function schema.validate(config)
    local errors = {}

    if not validate.expect_table(errors, "config", config) then
        return validate.result(errors)
    end

    if not validate.expect_integer(errors, "config.schema", config.schema) then
        return validate.result(errors)
    end

    if config.schema ~= constants.CONFIG_SCHEMA_VERSION then
        validate.push_error(errors, "config.schema", "unsupported schema version")
    end

    if not validate.expect_string(errors, "config.site", config.site, false) then
        return validate.result(errors)
    end

    if not validate.is_site_id(config.site) then
        validate.push_error(errors, "config.site", "invalid site id")
    end

    if not validate.expect_string(errors, "config.role", config.role, false) then
        return validate.result(errors)
    end

    if not constants.ROLE_SET[config.role] then
        validate.push_error(errors, "config.role", "unsupported role")
    end

    if validate.expect_table(errors, "config.modems", config.modems) then
        for key, value in pairs(config.modems) do
            if value ~= nil and type(value) ~= "string" then
                validate.push_error(errors, "config.modems." .. key, "expected modem side string")
            end
        end
    end

    if validate.expect_table(errors, "config.address_book", config.address_book) then
        if not validate.expect_string(errors, "config.address_book.mode", config.address_book.mode, false) then
            return validate.result(errors)
        end

        if not VALID_ADDRESS_BOOK_MODES[config.address_book.mode] then
            validate.push_error(errors, "config.address_book.mode", "unsupported address book mode")
        end

        if config.address_book.cache_path ~= nil then
            validate.expect_string(errors, "config.address_book.cache_path", config.address_book.cache_path, false)
        end

        if config.address_book.server_site ~= nil then
            validate.expect_string(errors, "config.address_book.server_site", config.address_book.server_site, false)
        end

        if config.address_book.server_path ~= nil then
            validate.expect_string(errors, "config.address_book.server_path", config.address_book.server_path, false)
        end
    end

    if validate.expect_table(errors, "config.security", config.security) then
        validate.expect_boolean(errors, "config.security.allowlist_enabled", config.security.allowlist_enabled)

        if validate.expect_table(errors, "config.security.allowed_computer_ids", config.security.allowed_computer_ids) then
            for index, computer_id in ipairs(config.security.allowed_computer_ids) do
                if not validate.is_integer(computer_id) then
                    validate.push_error(
                        errors,
                        "config.security.allowed_computer_ids[" .. index .. "]",
                        "expected integer computer id"
                    )
                end
            end
        end

        if config.security.shared_secret ~= nil then
            validate.expect_string(errors, "config.security.shared_secret", config.security.shared_secret, false)
        end
    end

    if config.logging ~= nil then
        if validate.expect_table(errors, "config.logging", config.logging) and config.logging.level ~= nil then
            if validate.expect_string(errors, "config.logging.level", config.logging.level, false) then
                if not VALID_LOG_LEVELS[config.logging.level] then
                    validate.push_error(errors, "config.logging.level", "unsupported log level")
                end
            end
        end
    end

    if config.update ~= nil then
        if validate.expect_table(errors, "config.update", config.update) then
            if config.update.mode ~= nil then
                if validate.expect_string(errors, "config.update.mode", config.update.mode, false) then
                    if not VALID_UPDATE_MODES[config.update.mode] then
                        validate.push_error(errors, "config.update.mode", "unsupported update mode")
                    end
                end
            end

            if config.update.base_url ~= nil then
                validate.expect_string(errors, "config.update.base_url", config.update.base_url, false)
            end

            if config.update.channel ~= nil then
                if validate.expect_string(errors, "config.update.channel", config.update.channel, false) then
                    if not validate.is_site_id(config.update.channel) then
                        validate.push_error(errors, "config.update.channel", "invalid update channel")
                    end
                end
            end

            if config.update.state_path ~= nil then
                validate.expect_string(errors, "config.update.state_path", config.update.state_path, false)
            end

            if config.update.temp_dir ~= nil then
                validate.expect_string(errors, "config.update.temp_dir", config.update.temp_dir, false)
            end

            if config.update.auto_reboot ~= nil then
                validate.expect_boolean(errors, "config.update.auto_reboot", config.update.auto_reboot)
            end
        end
    end

    local validation = validate.result(errors)
    if not validation.ok then
        return validation
    end

    return result.ok(config)
end

return schema
