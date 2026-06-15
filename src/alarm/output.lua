local constants = require("core.constants")
local result = require("core.result")

local output = {}

---@return table
function output.new_state()
    return {
        pulse_until = {},
        source_active = {},
        overrides = {},
    }
end

---@param left integer
---@param right integer
---@return integer
local function combine_mask(left, right)
    if type(colors) == "table" and type(colors.combine) == "function" then
        local ok, value = pcall(colors.combine, left, right)
        if ok and type(value) == "number" then
            return value
        end
    end

    return left + right
end

---@param signal_name string
---@param signals table<string, boolean>
---@return SgcResult
local function signal_value(signal_name, signals)
    if not constants.ALARM_SIGNAL_SET[signal_name] then
        return result.err("unsupported_alarm_signal", {
            signal = signal_name,
        })
    end

    return result.ok(signals[signal_name] == true)
end

---@param binding string|SgcAlarmOutputBinding
---@return SgcResult
local function normalize_binding(binding)
    if type(binding) == "string" then
        return result.ok({
            signal = binding,
            mode = "direct",
        })
    end

    if type(binding) ~= "table" then
        return result.err("invalid_alarm_output_binding", {
            binding = binding,
        })
    end

    if type(binding.signal) ~= "string" then
        return result.err("invalid_alarm_output_binding", {
            binding = binding,
            reason = "missing_signal",
        })
    end

    local mode = binding.mode
    if mode == nil then
        mode = "direct"
    end

    if type(mode) ~= "string" or constants.ALARM_OUTPUT_BINDING_MODE_SET[mode] ~= true then
        return result.err("invalid_alarm_output_binding_mode", {
            binding = binding,
            mode = mode,
        })
    end

    return result.ok({
        signal = binding.signal,
        mode = mode,
    })
end

---@param binding_key string
---@param binding string|SgcAlarmOutputBinding
---@param signals table<string, boolean>
---@param state table?
---@param now_ms integer?
---@return SgcResult
local function binding_snapshot(binding_key, binding, signals, state, now_ms)
    local normalized = normalize_binding(binding)
    if not normalized.ok then
        return normalized
    end

    local source_active = signal_value(normalized.value.signal, signals)
    if not source_active.ok then
        return source_active
    end

    local active = source_active.value
    if normalized.value.mode == "pulse" then
        active = state ~= nil
            and type(state.pulse_until[binding_key]) == "number"
            and state.pulse_until[binding_key] > (now_ms or 0)
            or false
    end

    local natural_active = active
    local override_active = nil
    if state ~= nil and type(state.overrides) == "table" then
        override_active = state.overrides[binding_key]
    end

    if type(override_active) == "boolean" then
        active = override_active
    end

    return result.ok({
        signal = normalized.value.signal,
        mode = normalized.value.mode,
        active = active,
        natural_active = natural_active,
        source_active = source_active.value,
        override_active = override_active,
    })
end

---@param state table?
---@param binding_key string
---@param binding string|SgcAlarmOutputBinding
---@param signals table<string, boolean>
---@param now_ms integer?
---@return SgcResult
local function binding_value(state, binding_key, binding, signals, now_ms)
    local snapshot = binding_snapshot(binding_key, binding, signals, state, now_ms)
    if not snapshot.ok then
        return snapshot
    end

    if snapshot.value.mode == "direct" then
        return result.ok(snapshot.value.active == true)
    end

    if state == nil then
        return result.err("missing_alarm_output_state", {
            binding_key = binding_key,
            mode = snapshot.value.mode,
        })
    end

    local previous_active = state.source_active[binding_key] == true
    if snapshot.value.source_active == true and previous_active ~= true then
        state.pulse_until[binding_key] = (now_ms or 0) + constants.ALARM_PULSE_DURATION_MS
    end
    state.source_active[binding_key] = snapshot.value.source_active == true

    if type(snapshot.value.override_active) == "boolean" then
        return result.ok(snapshot.value.override_active)
    end

    return result.ok(type(state.pulse_until[binding_key]) == "number" and state.pulse_until[binding_key] > (now_ms or 0))
end

---@param side string
---@param active boolean
---@param active_high boolean
---@return SgcResult
local function set_redstone_output(side, active, active_high)
    if redstone == nil or type(redstone.setOutput) ~= "function" then
        return result.err("redstone_unavailable", {
            side = side,
        })
    end

    local signal = nil
    if active_high then
        signal = active
    else
        signal = not active
    end

    local ok, set_error = pcall(redstone.setOutput, side, signal)
    if not ok then
        return result.err("redstone_output_failed", {
            side = side,
            cause = tostring(set_error),
        })
    end

    return result.ok(signal)
end

---@param side string
---@param channels table<string, string|SgcAlarmOutputBinding>
---@param signals table<string, boolean>
---@param state table?
---@param now_ms integer?
---@return SgcResult
local function build_bundled_mask(side, channels, signals, state, now_ms)
    if colors == nil then
        return result.err("colors_unavailable")
    end

    local mask = 0
    for color_name, binding in pairs(channels) do
        if not constants.BUNDLED_COLOR_SET[color_name] then
            return result.err("unsupported_bundled_color", {
                color = color_name,
            })
        end
        if not constants.BUNDLED_OUTPUT_COLOR_SET[color_name] then
            return result.err("reserved_bundled_output_color", {
                color = color_name,
            })
        end

        local wanted = binding_value(state, "bundled:" .. side .. ":" .. color_name, binding, signals, now_ms)
        if not wanted.ok then
            return wanted
        end

        if wanted.value then
            local color_value = colors[color_name]
            if type(color_value) ~= "number" then
                return result.err("missing_bundled_color_value", {
                    color = color_name,
                })
            end

            mask = combine_mask(mask, color_value)
        end
    end

    return result.ok(mask)
end

---@param side string
---@param channels table<string, string|SgcAlarmOutputBinding>
---@param signals table<string, boolean>
---@param state table?
---@param now_ms integer?
---@return SgcResult
local function set_bundled_output(side, channels, signals, state, now_ms)
    if redstone == nil or type(redstone.setBundledOutput) ~= "function" then
        return result.err("bundled_redstone_unavailable", {
            side = side,
        })
    end

    local mask = build_bundled_mask(side, channels, signals, state, now_ms)
    if not mask.ok then
        return mask
    end

    local ok, set_error = pcall(redstone.setBundledOutput, side, mask.value)
    if not ok then
        return result.err("bundled_output_failed", {
            side = side,
            cause = tostring(set_error),
        })
    end

    return result.ok(mask.value)
end

---@param definition table
---@param signals table<string, boolean>
---@param state table?
---@param now_ms integer?
---@return SgcResult
local function apply_one(definition, signals, state, now_ms)
    if definition.driver == "redstone" then
        local active = binding_value(state, "redstone:" .. definition.side, definition.signal, signals, now_ms)
        if not active.ok then
            return active
        end

        return set_redstone_output(definition.side, active.value, definition.active_high ~= false)
    end

    if definition.driver == "bundled" then
        return set_bundled_output(definition.side, definition.channels, signals, state, now_ms)
    end

    return result.err("unsupported_alarm_output_driver", {
        driver = definition.driver,
    })
end

---@param state table?
---@param definition table
local function clear_binding_state(state, definition)
    if state == nil then
        return
    end

    if definition.driver == "redstone" then
        state.source_active["redstone:" .. definition.side] = false
        state.pulse_until["redstone:" .. definition.side] = nil
        state.overrides["redstone:" .. definition.side] = nil
        return
    end

    if definition.driver ~= "bundled" or type(definition.channels) ~= "table" then
        return
    end

    for color_name, _binding in pairs(definition.channels) do
        local binding_key = "bundled:" .. definition.side .. ":" .. color_name
        state.source_active[binding_key] = false
        state.pulse_until[binding_key] = nil
        state.overrides[binding_key] = nil
    end
end

---@param state table
---@param binding_key string
---@param active boolean
---@param natural_active boolean
function output.set_override(state, binding_key, active, natural_active)
    if type(state) ~= "table" or type(binding_key) ~= "string" then
        return
    end

    if active == natural_active then
        state.overrides[binding_key] = nil
        return
    end

    state.overrides[binding_key] = active == true
end

---@param state table
---@param binding_key string
---@param current_active boolean
---@param natural_active boolean
---@return boolean
function output.toggle_override(state, binding_key, current_active, natural_active)
    local next_active = current_active ~= true
    output.set_override(state, binding_key, next_active, natural_active)
    return next_active
end

---@param outputs table[]
---@param signals table<string, boolean>
---@param state table?
---@param now_ms integer?
---@return SgcResult
function output.apply(outputs, signals, state, now_ms)
    local applied = {}
    for index, definition in ipairs(outputs) do
        local operation = apply_one(definition, signals, state, now_ms)
        if not operation.ok then
            return result.err(operation.error, {
                output_index = index,
                output = definition,
                cause = operation.details,
            })
        end

        applied[#applied + 1] = {
            driver = definition.driver,
            side = definition.side,
            value = operation.value,
        }
    end

    return result.ok(applied)
end

---@param outputs table[]
---@param state table?
---@return SgcResult
function output.clear(outputs, state)
    local applied = {}
    for index, definition in ipairs(outputs) do
        local operation = nil
        if definition.driver == "redstone" then
            operation = set_redstone_output(definition.side, false, definition.active_high ~= false)
        elseif definition.driver == "bundled" then
            operation = set_bundled_output(definition.side, {}, {}, state, 0)
        else
            operation = result.err("unsupported_alarm_output_driver", {
                driver = definition.driver,
            })
        end

        if not operation.ok then
            return result.err(operation.error, {
                output_index = index,
                output = definition,
                cause = operation.details,
            })
        end

        clear_binding_state(state, definition)
        applied[#applied + 1] = {
            driver = definition.driver,
            side = definition.side,
            value = operation.value,
        }
    end

    return result.ok(applied)
end

---@param outputs table[]
---@param signals table<string, boolean>
---@param state table?
---@param now_ms integer?
---@return SgcResult
function output.snapshot(outputs, signals, state, now_ms)
    local entries = {}

    for output_index, definition in ipairs(outputs) do
        if definition.driver == "redstone" then
            local snapshot = binding_snapshot("redstone:" .. definition.side, definition.signal, signals, state, now_ms)
            if not snapshot.ok then
                return snapshot
            end

            entries[#entries + 1] = {
                output_index = output_index,
                driver = definition.driver,
                side = definition.side,
                binding_key = "redstone:" .. definition.side,
                signal = snapshot.value.signal,
                mode = snapshot.value.mode,
                active = snapshot.value.active,
                natural_active = snapshot.value.natural_active,
                override_active = snapshot.value.override_active,
                wire_color = nil,
            }
        elseif definition.driver == "bundled" then
            for _, color_name in ipairs(constants.BUNDLED_COLOR_NAMES) do
                local binding = type(definition.channels) == "table" and definition.channels[color_name] or nil
                if binding ~= nil then
                    if not constants.BUNDLED_OUTPUT_COLOR_SET[color_name] then
                        return result.err("reserved_bundled_output_color", {
                            color = color_name,
                        })
                    end

                    local snapshot = binding_snapshot(
                        "bundled:" .. definition.side .. ":" .. color_name,
                        binding,
                        signals,
                        state,
                        now_ms
                    )
                    if not snapshot.ok then
                        return snapshot
                    end

                    entries[#entries + 1] = {
                        output_index = output_index,
                        driver = definition.driver,
                        side = definition.side,
                        binding_key = "bundled:" .. definition.side .. ":" .. color_name,
                        signal = snapshot.value.signal,
                        mode = snapshot.value.mode,
                        active = snapshot.value.active,
                        natural_active = snapshot.value.natural_active,
                        override_active = snapshot.value.override_active,
                        wire_color = color_name,
                    }
                end
            end
        else
            return result.err("unsupported_alarm_output_driver", {
                driver = definition.driver,
            })
        end
    end

    return result.ok(entries)
end

return output
