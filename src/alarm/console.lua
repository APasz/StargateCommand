local config_defaults = require("config.default")
local config_schema = require("config.schema")
local constants = require("core.constants")
local persistence = require("core.persistence")
local result = require("core.result")
local tablex = require("core.tablex")
local ui_term = require("ui.term")

local console = {}

local DEFAULT_CONFIG_PATH = "config.lua"

local COMMAND_SPECS = {
    {
        summary = "help",
        description = "Show available commands",
    },
    {
        summary = "show",
        description = "Show the active alarm config summary",
    },
    {
        summary = "edit",
        description = "Edit and save the alarm config",
    },
    {
        summary = "path",
        description = "Show the config file path that will be edited",
    },
}

---@alias SgcAlarmConfigEditorText string|string[]

---@param value any
---@return string?
local function optional_string(value)
    if type(value) == "string" and value ~= "" then
        return value
    end

    return nil
end

---@param values string[]
---@return string
local function join_values(values)
    return table.concat(values, ", ")
end

---@param lines string[]
---@param text SgcAlarmConfigEditorText?
local function append_text(lines, text)
    if type(text) == "table" then
        for _, line in ipairs(text) do
            lines[#lines + 1] = line
        end
    elseif type(text) == "string" and text ~= "" then
        lines[#lines + 1] = text
    end
end

---@param title string
---@param key string
---@param current_value string?
---@param default_value string?
---@param expected SgcAlarmConfigEditorText?
---@param description SgcAlarmConfigEditorText?
---@param error_message string?
---@return string
local function read_prompt(title, key, current_value, default_value, expected, description, error_message)
    local answer = ui_term.read_prompt_page({
        title = title,
        key = key,
        current_value = current_value,
        default_value = default_value,
        expected = expected,
        description = description,
        error = error_message,
        input_label = "> ",
    })
    if answer == nil then
        error("terminal input is unavailable")
    end

    return answer
end

---@param title string
---@param key string
---@param current_value string?
---@param default_value string?
---@param expected SgcAlarmConfigEditorText?
---@param help_text SgcAlarmConfigEditorText?
---@return string
local function read_required_text(title, key, current_value, default_value, expected, help_text)
    local error_message = nil
    while true do
        local description = {}
        append_text(description, help_text)
        if current_value ~= nil then
            description[#description + 1] = "Press Enter to keep the current value."
        elseif default_value ~= nil then
            description[#description + 1] = "Press Enter to use the default value."
        else
            description[#description + 1] = "Enter a value for this field."
        end

        local answer = read_prompt(title, key, current_value, default_value, expected, description, error_message)
        if answer == "" and current_value ~= nil then
            return current_value
        end
        if answer == "" and default_value ~= nil then
            return default_value
        end
        if answer ~= "" then
            return answer
        end

        error_message = "Please enter a value."
    end
end

---@param title string
---@param key string
---@param current_value string?
---@param choices string[]
---@param help_text SgcAlarmConfigEditorText?
---@return string
local function read_choice(title, key, current_value, choices, help_text)
    local allowed = {}
    for _, choice in ipairs(choices) do
        allowed[choice] = true
    end

    local error_message = nil
    while true do
        local description = {}
        append_text(description, help_text)
        description[#description + 1] = "Press Enter to keep the current value."

        local answer = read_prompt(title, key, current_value, nil, "one of: " .. join_values(choices), description, error_message)
        if answer == "" and current_value ~= nil then
            return current_value
        end
        if allowed[answer] then
            return answer
        end

        error_message = "Expected one of: " .. join_values(choices)
    end
end

---@param title string
---@param key string
---@param choices string[]
---@param used_values table<string, boolean>
---@param help_text SgcAlarmConfigEditorText?
---@return string
local function read_unused_choice(title, key, choices, used_values, help_text)
    local error_message = nil
    while true do
        local description = {}
        append_text(description, help_text)
        local answer = read_prompt(title, key, nil, nil, "one of: " .. join_values(choices), description, error_message)
        if used_values[answer] then
            error_message = "That value is already used."
        else
            for _, choice in ipairs(choices) do
                if answer == choice then
                    return answer
                end
            end
            error_message = "Expected one of: " .. join_values(choices)
        end
    end
end

---@param title string
---@param key string
---@param current_value boolean?
---@param default_value boolean
---@param help_text SgcAlarmConfigEditorText?
---@return boolean
local function read_boolean(title, key, current_value, default_value, help_text)
    local current_text = current_value ~= nil and (current_value and "yes" or "no") or nil
    local default_text = current_value == nil and (default_value and "yes" or "no") or nil
    local fallback = current_value
    if fallback == nil then
        fallback = default_value
    end

    local error_message = nil
    while true do
        local description = {}
        append_text(description, help_text)
        description[#description + 1] = "Accepted values: y, yes, n, no."
        description[#description + 1] = "Press Enter to use the shown value."
        local answer = string.lower(read_prompt(title, key, current_text, default_text, "yes or no", description, error_message))
        if answer == "" then
            return fallback
        end
        if answer == "y" or answer == "yes" then
            return true
        end
        if answer == "n" or answer == "no" then
            return false
        end

        error_message = "Please answer yes or no."
    end
end

---@param title string
---@param key string
---@param current_value number?
---@param minimum number
---@param integer_only boolean
---@param help_text SgcAlarmConfigEditorText?
---@return number
local function read_number(title, key, current_value, minimum, integer_only, help_text)
    local error_message = nil
    while true do
        local expected = integer_only
            and "integer >= " .. tostring(minimum)
            or "number > " .. tostring(minimum)
        local answer = read_prompt(
            title,
            key,
            current_value ~= nil and tostring(current_value) or nil,
            nil,
            expected,
            help_text,
            error_message
        )
        if answer == "" and current_value ~= nil then
            return current_value
        end

        local parsed = tonumber(answer)
        local valid = parsed ~= nil and (integer_only and parsed >= minimum or parsed > minimum)
        if valid and integer_only then
            valid = parsed % 1 == 0
        end
        if valid then
            return parsed
        end

        error_message = "Expected " .. expected .. "."
    end
end

---@param binding string|table|nil
---@return string?
local function binding_signal(binding)
    if type(binding) == "string" then
        return binding
    end
    if type(binding) == "table" then
        return binding.signal
    end
    return nil
end

---@param binding string|table|nil
---@return string
local function binding_mode(binding)
    if type(binding) == "table" and type(binding.mode) == "string" then
        return binding.mode
    end
    return "direct"
end

---@param signal_name string
---@param mode string
---@return string|table
local function build_binding(signal_name, mode)
    if mode == "direct" then
        return signal_name
    end

    return {
        signal = signal_name,
        mode = mode,
    }
end

---@param title string
---@param key string
---@param current_binding string|table|nil
---@return string|table
local function read_signal_binding(title, key, current_binding)
    local signal_name = read_choice(
        title,
        key .. " signal",
        binding_signal(current_binding),
        constants.ALARM_SIGNAL_NAMES,
        "Signal that activates this output binding."
    )
    local mode = read_choice(
        title,
        key .. " mode",
        binding_mode(current_binding),
        { "direct", "pulse" },
        "Direct follows the signal while pulse emits one short activation when the signal becomes active."
    )

    return build_binding(signal_name, mode)
end

---@return string[]
local function bundled_output_colors()
    local values = {}
    for _, color_name in ipairs(constants.BUNDLED_COLOR_NAMES) do
        if constants.BUNDLED_OUTPUT_COLOR_SET[color_name] then
            values[#values + 1] = color_name
        end
    end
    return values
end

---@param output table?
---@return string
local function output_driver(output)
    return type(output) == "table" and optional_string(output.driver) or "redstone"
end

---@param output table?
---@return string?
local function output_side(output)
    return type(output) == "table" and optional_string(output.side) or nil
end

---@param values table?
---@return integer
local function table_key_count(values)
    if type(values) ~= "table" then
        return 0
    end

    local count = 0
    for _key, _value in pairs(values) do
        count = count + 1
    end
    return count
end

---@param title string
---@param index integer
---@param current_output table?
---@return table
local function read_redstone_output(title, index, current_output)
    local prefix = "Output " .. tostring(index)
    local side = read_required_text(title, prefix .. " side", output_side(current_output), nil, "ComputerCraft side", {
        "Redstone output side such as left, right, back, top, bottom, or front.",
    })
    local signal_binding = read_signal_binding(title, prefix, current_output ~= nil and current_output.signal or nil)
    local active_high = read_boolean(
        title,
        prefix .. " active high",
        current_output ~= nil and current_output.active_high or nil,
        true,
        "When yes, active signals set redstone on. When no, active signals set redstone off."
    )

    return {
        driver = "redstone",
        side = side,
        signal = signal_binding,
        active_high = active_high,
    }
end

---@param title string
---@param index integer
---@param current_output table?
---@return table
local function read_bundled_output(title, index, current_output)
    local prefix = "Output " .. tostring(index)
    local side = read_required_text(title, prefix .. " side", output_side(current_output), nil, "ComputerCraft side", {
        "Bundled redstone side such as left, right, back, top, bottom, or front.",
    })
    local current_channels = type(current_output) == "table" and current_output.channels or {}
    local channel_count = read_number(
        title,
        prefix .. " channel count",
        table_key_count(current_channels) > 0 and table_key_count(current_channels) or 1,
        1,
        true,
        "Number of bundled color channels to configure for this side."
    )
    local colors_by_index = bundled_output_colors()
    local channels = {}
    local used_colors = {}
    for channel_index = 1, channel_count do
        local channel_key = prefix .. " channel " .. tostring(channel_index)
        local color_name = read_unused_choice(title, channel_key .. " color", colors_by_index, used_colors, {
            "Bundled output color. White and black are reserved and not available here.",
        })
        used_colors[color_name] = true
        channels[color_name] = read_signal_binding(title, channel_key, current_channels[color_name])
    end

    return {
        driver = "bundled",
        side = side,
        channels = channels,
    }
end

---@param title string
---@param index integer
---@param current_output table?
---@return table
local function read_output(title, index, current_output)
    local driver = read_choice(title, "Output " .. tostring(index) .. " driver", output_driver(current_output), {
        "redstone",
        "bundled",
    }, "Redstone uses one side for one signal. Bundled maps multiple color channels on one side.")

    if driver == "bundled" then
        return read_bundled_output(title, index, current_output)
    end

    return read_redstone_output(title, index, current_output)
end

---@param title string
---@param current_outputs table[]?
---@return table[]
local function read_outputs(title, current_outputs)
    local outputs = type(current_outputs) == "table" and current_outputs or {}
    local count = read_number(title, "Output count", #outputs > 0 and #outputs or 1, 1, true, {
        "How many redstone or bundled output definitions the alarm controller should drive.",
    })
    local updated = {}
    for index = 1, count do
        updated[index] = read_output(title, index, outputs[index])
    end

    return updated
end

---@param title string
---@param index integer
---@param current_binding table?
---@return table
local function read_speaker_binding(title, index, current_binding)
    local prefix = "Speaker " .. tostring(index)
    local signal_name = read_choice(
        title,
        prefix .. " signal",
        type(current_binding) == "table" and current_binding.signal or nil,
        constants.ALARM_SIGNAL_NAMES,
        "Signal that starts this speaker pattern."
    )
    local pattern = read_choice(
        title,
        prefix .. " pattern",
        type(current_binding) == "table" and current_binding.pattern or nil,
        { "pattern_alpha", "pattern_beta" },
        "Pattern played while this speaker binding is selected."
    )

    return {
        signal = signal_name,
        pattern = pattern,
    }
end

---@param title string
---@param current_bindings table[]?
---@return table[]
local function read_speaker_bindings(title, current_bindings)
    local bindings = type(current_bindings) == "table" and current_bindings or {}
    local count = read_number(title, "Speaker binding count", #bindings, 0, true, {
        "Speaker bindings are priority ordered. system_error is selected ahead of other active signals.",
    })
    local updated = {}
    for index = 1, count do
        updated[index] = read_speaker_binding(title, index, bindings[index])
    end
    return updated
end

---@param config table
---@param alarm table
---@return table
function console.apply_alarm_config(config, alarm)
    local updated = tablex.deep_copy(config)
    updated.alarm = tablex.deep_copy(alarm)
    updated.alarm.output_side = nil
    updated.alarm.active_high = nil
    return updated
end

---@param config table
---@return SgcResult
function console.validate_config(config)
    return config_schema.validate(config)
end

---@param path string
---@return SgcResult
function console.load_config(path)
    local loaded = nil
    if persistence.exists(path) then
        local ok, value = pcall(dofile, path)
        if not ok then
            return result.err("config_load_failed", {
                path = path,
                cause = tostring(value),
            })
        end
        loaded = value
    else
        loaded = config_defaults.for_role("alarm_controller")
    end

    local validation = config_schema.validate(loaded)
    if not validation.ok then
        return validation
    end
    if validation.value.role ~= "alarm_controller" then
        return result.err("wrong_config_role", {
            role = validation.value.role,
            expected = "alarm_controller",
        })
    end

    return result.ok(config_defaults.for_role("alarm_controller", validation.value))
end

---@param path string
---@param config table
---@return SgcResult
function console.save_config(path, config)
    local validation = config_schema.validate(config)
    if not validation.ok then
        return validation
    end

    if fs == nil or type(fs.open) ~= "function" or type(fs.makeDir) ~= "function" then
        return result.err("filesystem_unavailable", {
            path = path,
        })
    end
    if textutils == nil or type(textutils.serialize) ~= "function" then
        return result.err("textutils_unavailable", {
            path = path,
        })
    end

    local parent = persistence.dirname(path)
    if parent ~= nil and parent ~= "" and type(fs.exists) == "function" and not fs.exists(parent) then
        fs.makeDir(parent)
    end

    local handle = fs.open(path, "w")
    if handle == nil then
        return result.err("file_write_failed", {
            path = path,
        })
    end

    handle.write("return ")
    handle.write(textutils.serialize(validation.value, { compact = false }))
    handle.write("\n")
    handle.close()

    return result.ok(validation.value)
end

---@param paths string[]?
---@return string
function console.resolve_config_path(paths)
    for _, path in ipairs(paths or constants.DEFAULT_CONFIG_PATHS) do
        if persistence.exists(path) then
            return path
        end
    end

    return DEFAULT_CONFIG_PATH
end

---@param config table
---@return table
function console.prompt_alarm_config(config)
    local title = "Alarm Controller Config"
    local alarm = type(config.alarm) == "table" and config.alarm or {}
    local updated_alarm = {
        poll_interval_ms = read_number(title, "Poll interval ms", alarm.poll_interval_ms, 0, true, {
            "How often the alarm controller polls gate and site status when no network events arrive.",
        }),
        monitor_text_scale = read_number(title, "Monitor text scale", alarm.monitor_text_scale, 0, false, {
            "Text scale used by the alarm monitor on the peripheral modem side.",
        }),
        trigger_on_fault = read_boolean(title, "Trigger on fault", alarm.trigger_on_fault, true, {
            "When yes, missing or stale gate/site status raises system_error.",
        }),
        outputs = read_outputs(title, alarm.outputs),
        speaker = {
            bindings = read_speaker_bindings(title, alarm.speaker ~= nil and alarm.speaker.bindings or nil),
        },
    }

    return updated_alarm
end

---@param path string?
---@return SgcResult
function console.edit_file(path)
    local config_path = path or DEFAULT_CONFIG_PATH
    local loaded = console.load_config(config_path)
    if not loaded.ok then
        return loaded
    end

    local alarm = console.prompt_alarm_config(loaded.value)
    local updated = console.apply_alarm_config(loaded.value, alarm)
    local validation = console.validate_config(updated)
    if not validation.ok then
        return validation
    end

    local should_save = read_boolean("Alarm Controller Config", "Save changes", nil, true, {
        "Writes the updated alarm section to " .. config_path .. ".",
    })
    if not should_save then
        return result.ok({
            saved = false,
            config = validation.value,
        })
    end

    local saved = console.save_config(config_path, validation.value)
    if not saved.ok then
        return saved
    end

    return result.ok({
        saved = true,
        path = config_path,
        config = saved.value,
    })
end

---@param message string
local function print_error(message)
    if type(printError) == "function" then
        printError("[sgc] " .. message)
        return
    end

    print("[sgc] " .. message)
end

---@param line string
---@return string[]
local function tokenize(line)
    local parts = {}
    for part in tostring(line):gmatch("%S+") do
        parts[#parts + 1] = part
    end

    return parts
end

local function print_help()
    ui_term.show_help_screen(COMMAND_SPECS, "alarm_controller")
end

local function print_console_home()
    ui_term.console_header(COMMAND_SPECS, "alarm_controller")
    print("Alarm config console ready.")
end

---@param alarm table
local function print_alarm_summary(alarm)
    print("Alarm config")
    print("Poll interval ms: " .. tostring(alarm.poll_interval_ms))
    print("Monitor text scale: " .. tostring(alarm.monitor_text_scale))
    print("Trigger on fault: " .. tostring(alarm.trigger_on_fault == true))
    print("Outputs: " .. tostring(type(alarm.outputs) == "table" and #alarm.outputs or 0))
    local speaker_bindings = alarm.speaker ~= nil and alarm.speaker.bindings or nil
    print("Speaker bindings: " .. tostring(type(speaker_bindings) == "table" and #speaker_bindings or 0))
end

---@param mutation_result SgcResult
local function print_validation_errors(mutation_result)
    local errors = mutation_result.details ~= nil and mutation_result.details.errors or nil
    if type(errors) ~= "table" or #errors == 0 then
        return
    end

    print("Validation errors:")
    for _, failure in ipairs(errors) do
        local path = type(failure.path) == "string" and failure.path or "unknown"
        local message = type(failure.message) == "string" and failure.message or "validation failed"
        print(string.format(" - %s: %s", path, message))
    end
end

---@param config table
---@param config_path string
---@return SgcResult
local function prompt_and_save(config, config_path)
    local alarm = console.prompt_alarm_config(config)
    local updated = console.apply_alarm_config(config, alarm)
    local validation = console.validate_config(updated)
    if not validation.ok then
        print_error("updated alarm config failed validation")
        print_validation_errors(validation)
        return validation
    end

    local should_save = read_boolean("Alarm Controller Config", "Save changes", nil, true, {
        "Writes the updated alarm section to " .. config_path .. ".",
    })
    if not should_save then
        print("Cancelled.")
        return result.ok({
            saved = false,
            config = validation.value,
        })
    end

    local saved = console.save_config(config_path, validation.value)
    if not saved.ok then
        print_error("failed to save alarm config: " .. tostring(saved.error))
        return saved
    end

    print("Saved alarm config: " .. config_path)
    return result.ok({
        saved = true,
        path = config_path,
        config = saved.value,
    })
end

---@param config table
---@param runtime table
---@param logger table?
---@param on_saved fun(updated_config: table): SgcResult?
function console.run(config, runtime, logger, on_saved)
    local config_path = console.resolve_config_path()
    print_console_home()

    while true do
        write("alarm-config> ")
        local line = read()
        local parts = tokenize(line)
        local command = parts[1]
        if command == nil then
        elseif command == "help" then
            print_help()
            print_console_home()
        elseif command == "show" then
            print_alarm_summary(runtime.alarm or config.alarm or {})
        elseif command == "path" then
            print(config_path)
        elseif command == "edit" then
            local edited = prompt_and_save(runtime.config or config, config_path)
            if edited.ok and edited.value.saved == true and type(on_saved) == "function" then
                local applied = on_saved(edited.value.config)
                if not applied.ok then
                    print_error("saved config but live reload failed: " .. tostring(applied.error))
                elseif logger ~= nil and type(logger.info) == "function" then
                    logger:info("alarm config updated from console", {
                        path = config_path,
                    })
                end
            end
        else
            print_error("unknown command: " .. tostring(command))
        end
    end
end

return console
