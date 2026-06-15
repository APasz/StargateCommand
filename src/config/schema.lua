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

---@param errors table[]
---@param path string
---@param outputs table[]
local function validate_alarm_output_side_conflicts(errors, path, outputs)
    local side_drivers = {}

    for index, output in ipairs(outputs) do
        if type(output) == "table" and type(output.side) == "string" and type(output.driver) == "string" then
            local previous_driver = side_drivers[output.side]
            if previous_driver ~= nil and previous_driver ~= output.driver then
                validate.push_error(
                    errors,
                    path .. "[" .. index .. "].side",
                    "cannot mix redstone and bundled outputs on the same side"
                )
            else
                side_drivers[output.side] = output.driver
            end
        end
    end
end

---@param errors table[]
---@param path string
---@param binding any
local function validate_alarm_signal_binding(errors, path, binding)
    if type(binding) == "string" then
        if binding == "" then
            validate.push_error(errors, path, "expected non-empty string")
        elseif not constants.ALARM_SIGNAL_SET[binding] then
            validate.push_error(errors, path, "unsupported alarm signal")
        end

        return
    end

    if not validate.expect_table(errors, path, binding) then
        return
    end

    if validate.expect_string(errors, path .. ".signal", binding.signal, false) then
        if not constants.ALARM_SIGNAL_SET[binding.signal] then
            validate.push_error(errors, path .. ".signal", "unsupported alarm signal")
        end
    end

    if binding.mode ~= nil then
        if validate.expect_string(errors, path .. ".mode", binding.mode, false) then
            if not constants.ALARM_OUTPUT_BINDING_MODE_SET[binding.mode] then
                validate.push_error(errors, path .. ".mode", "unsupported alarm output binding mode")
            end
        end
    end
end

---@param errors table[]
---@param path string
---@param channels table
local function validate_alarm_channels(errors, path, channels)
    local channel_count = 0
    for color_name, binding in pairs(channels) do
        channel_count = channel_count + 1
        if not constants.BUNDLED_COLOR_SET[color_name] then
            validate.push_error(errors, path .. "." .. tostring(color_name), "unsupported bundled color")
        elseif not constants.BUNDLED_OUTPUT_COLOR_SET[color_name] then
            validate.push_error(errors, path .. "." .. tostring(color_name), "bundled output color is reserved")
        end

        validate_alarm_signal_binding(errors, path .. "." .. tostring(color_name), binding)
    end

    if channel_count == 0 then
        validate.push_error(errors, path, "expected at least one bundled channel")
    end
end

---@param errors table[]
---@param path string
---@param output table
local function validate_alarm_output(errors, path, output)
    if not validate.expect_table(errors, path, output) then
        return
    end

    if validate.expect_string(errors, path .. ".driver", output.driver, false) then
        if not constants.ALARM_OUTPUT_DRIVER_SET[output.driver] then
            validate.push_error(errors, path .. ".driver", "unsupported alarm output driver")
        end
    end

    validate.expect_string(errors, path .. ".side", output.side, false)

    if output.driver == "redstone" then
        validate_alarm_signal_binding(errors, path .. ".signal", output.signal)

        if output.active_high ~= nil then
            validate.expect_boolean(errors, path .. ".active_high", output.active_high)
        end
    elseif output.driver == "bundled" then
        if validate.expect_table(errors, path .. ".channels", output.channels) then
            validate_alarm_channels(errors, path .. ".channels", output.channels)
        end

        if output.signal ~= nil then
            validate.push_error(errors, path .. ".signal", "signal is only valid for redstone outputs")
        end

        if output.active_high ~= nil then
            validate.push_error(errors, path .. ".active_high", "active_high is only valid for redstone outputs")
        end
    end
end

---@param errors table[]
---@param path string
---@param binding table
local function validate_alarm_speaker_binding(errors, path, binding)
    if not validate.expect_table(errors, path, binding) then
        return
    end

    validate_alarm_signal_binding(errors, path .. ".signal", binding.signal)

    if validate.expect_string(errors, path .. ".pattern", binding.pattern, false) then
        if not constants.ALARM_SPEAKER_PATTERN_SET[binding.pattern] then
            validate.push_error(errors, path .. ".pattern", "unsupported alarm speaker pattern")
        end
    end
end

---@param errors table[]
---@param path string
---@param speaker table
local function validate_alarm_speaker(errors, path, speaker)
    if not validate.expect_table(errors, path, speaker) then
        return
    end

    if speaker.bindings ~= nil then
        if validate.expect_table(errors, path .. ".bindings", speaker.bindings) then
            for index, binding in ipairs(speaker.bindings) do
                validate_alarm_speaker_binding(errors, path .. ".bindings[" .. index .. "]", binding)
            end

            for key, _value in pairs(speaker.bindings) do
                if type(key) ~= "number" then
                    validate.push_error(errors, path .. ".bindings", "expected ordered speaker bindings list")
                    break
                end
            end
        end
    end
end

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

        if config.address_book.bootstrap_on_missing ~= nil then
            validate.expect_boolean(errors, "config.address_book.bootstrap_on_missing", config.address_book.bootstrap_on_missing)
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

    if config.dial_console ~= nil then
        if validate.expect_table(errors, "config.dial_console", config.dial_console) then
            if config.dial_console.monitor_text_scale ~= nil then
                if type(config.dial_console.monitor_text_scale) ~= "number" then
                    validate.push_error(errors, "config.dial_console.monitor_text_scale", "expected number")
                elseif config.dial_console.monitor_text_scale <= 0 then
                    validate.push_error(errors, "config.dial_console.monitor_text_scale", "expected number > 0")
                end
            end
        end
    end

        if config.alarm ~= nil then
        if validate.expect_table(errors, "config.alarm", config.alarm) then
            if config.alarm.poll_interval_ms ~= nil then
                if validate.expect_integer(errors, "config.alarm.poll_interval_ms", config.alarm.poll_interval_ms) then
                    if config.alarm.poll_interval_ms < 0 then
                        validate.push_error(errors, "config.alarm.poll_interval_ms", "expected integer >= 0")
                    end
                end
            end

            if config.alarm.monitor_text_scale ~= nil then
                if type(config.alarm.monitor_text_scale) ~= "number" then
                    validate.push_error(errors, "config.alarm.monitor_text_scale", "expected number")
                elseif config.alarm.monitor_text_scale <= 0 then
                    validate.push_error(errors, "config.alarm.monitor_text_scale", "expected number > 0")
                end
            end

            if config.alarm.trigger_on_fault ~= nil then
                validate.expect_boolean(errors, "config.alarm.trigger_on_fault", config.alarm.trigger_on_fault)
            end

            if config.alarm.output_side ~= nil then
                validate.expect_string(errors, "config.alarm.output_side", config.alarm.output_side, false)
            end

            if config.alarm.active_high ~= nil then
                validate.expect_boolean(errors, "config.alarm.active_high", config.alarm.active_high)
            end

            if config.alarm.outputs ~= nil then
                if validate.expect_table(errors, "config.alarm.outputs", config.alarm.outputs) then
                    if #config.alarm.outputs == 0 then
                        validate.push_error(errors, "config.alarm.outputs", "expected at least one alarm output")
                    end

                    for index, output in ipairs(config.alarm.outputs) do
                        validate_alarm_output(errors, "config.alarm.outputs[" .. index .. "]", output)
                    end

                    validate_alarm_output_side_conflicts(errors, "config.alarm.outputs", config.alarm.outputs)
                end
            end

            if config.alarm.speaker ~= nil then
                validate_alarm_speaker(errors, "config.alarm.speaker", config.alarm.speaker)
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
