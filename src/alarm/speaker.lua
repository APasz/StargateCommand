local resolver = require("peripheral.resolver")
local result = require("core.result")
local time = require("core.time")

local speaker = {}
local PATTERNS = {
    pattern_alpha = {
        {
            instrument = "didgeridoo",
            volume = 3.0,
            pitch = 8,
            delay_ms = 180,
        },
        {
            instrument = "didgeridoo",
            volume = 3.0,
            pitch = 5,
            delay_ms = 180,
        },
        {
            instrument = "didgeridoo",
            volume = 3.0,
            pitch = 8,
            delay_ms = 540,
        },
    },
    pattern_beta = {
        {
            instrument = "didgeridoo",
            volume = 3.0,
            pitch = 6,
            delay_ms = 250,
        },
        {
            instrument = "didgeridoo",
            volume = 3.0,
            pitch = 3,
            delay_ms = 700,
        },
    },
}

---@param config table?
---@return table
function speaker.new_runtime(config)
    local resolved_config = type(config) == "table" and config or {}
    return {
        bindings = type(resolved_config.bindings) == "table" and resolved_config.bindings or {},
        peripheral_side = resolved_config.peripheral_side,
        overrides = {},
        active = false,
        active_binding_index = nil,
        active_signal = nil,
        active_pattern = nil,
        step_index = 1,
        next_play_at = 0,
        resolved_speakers = nil,
    }
end

---@param candidate table?
---@return boolean
local function is_speaker(candidate)
    return type(candidate) == "table"
        and type(candidate.playNote) == "function"
        and type(candidate.stop) == "function"
end

---@param peripheral_side string?
---@return SgcResult
local function resolve_speakers(peripheral_side)
    if type(peripheral_side) ~= "string" or peripheral_side == "" then
        return result.err("missing_speaker_side")
    end

    return resolver.resolve_all(peripheral_side, "speaker", is_speaker)
end

---@param resolved_speakers table[]
---@return SgcResult
local function stop_speakers(resolved_speakers)
    for _, resolved in ipairs(resolved_speakers) do
        local ok, stop_error = pcall(resolved.peripheral.stop)
        if not ok then
            return result.err("speaker_stop_failed", {
                speaker_id = resolved.id,
                cause = tostring(stop_error),
            })
        end
    end

    return result.ok(true)
end

---@param runtime table
local function invalidate_resolved_speakers(runtime)
    runtime.resolved_speakers = nil
end

---@param runtime table
---@return SgcResult
local function resolve_runtime_speakers(runtime)
    if type(runtime.resolved_speakers) == "table" and #runtime.resolved_speakers > 0 then
        return result.ok(runtime.resolved_speakers)
    end

    local resolved = resolve_speakers(runtime.peripheral_side)
    if not resolved.ok then
        if resolved.error == "missing_speaker" or resolved.error == "missing_speaker_side" then
            invalidate_resolved_speakers(runtime)
            return result.ok({})
        end

        return resolved
    end

    runtime.resolved_speakers = resolved.value
    return result.ok(resolved.value)
end

---@param runtime table
---@return SgcResult
function speaker.clear_runtime(runtime)
    local resolved = resolve_runtime_speakers(runtime)
    if not resolved.ok then
        return resolved
    end

    if #resolved.value == 0 then
        return result.ok(false)
    end

    local stopped = stop_speakers(resolved.value)
    if not stopped.ok then
        invalidate_resolved_speakers(runtime)
        return stopped
    end

    return stopped
end

---@param peripheral_side string?
---@return SgcResult
function speaker.clear(peripheral_side)
    return speaker.clear_runtime(speaker.new_runtime({
        peripheral_side = peripheral_side,
    }))
end

---@param runtime table
local function reset_runtime(runtime)
    runtime.active = false
    runtime.active_binding_index = nil
    runtime.active_signal = nil
    runtime.active_pattern = nil
    runtime.step_index = 1
    runtime.next_play_at = 0
    runtime.resolved_speakers = nil
end

---@param index integer
---@return string
local function binding_key(index)
    return "speaker:" .. tostring(index)
end

---@param runtime table?
---@return table
local function ensure_overrides(runtime)
    if type(runtime) ~= "table" then
        return {}
    end

    if type(runtime.overrides) ~= "table" then
        runtime.overrides = {}
    end

    return runtime.overrides
end

---@param runtime table?
---@param bindings SgcAlarmSpeakerBinding[]
---@param signals table<string, boolean>
---@return table[]
local function binding_states(runtime, bindings, signals)
    local overrides = ensure_overrides(runtime)
    local states = {}

    for index, binding in ipairs(bindings or {}) do
        if type(binding) == "table" then
            local source_active = signals[binding.signal] == true
            local override_active = overrides[binding_key(index)]
            local active = type(override_active) == "boolean" and override_active or source_active
            states[#states + 1] = {
                index = index,
                binding_key = binding_key(index),
                signal = binding.signal,
                pattern = binding.pattern,
                source_active = source_active,
                override_active = override_active,
                active = active,
            }
        end
    end

    return states
end

---@param states table[]
---@return table?
local function select_binding(states)
    local first_active = nil
    local system_error_active = nil
    local first_manual = nil
    local system_error_manual = nil

    for _, state in ipairs(states or {}) do
        if state.override_active == true then
            local selected = {
                index = state.index,
                signal = state.signal,
                pattern = state.pattern,
            }
            if first_manual == nil then
                first_manual = selected
            end
            if state.signal == "system_error" and system_error_manual == nil then
                system_error_manual = selected
            end
        elseif state.active == true then
            local selected = {
                index = state.index,
                signal = state.signal,
                pattern = state.pattern,
            }
            if first_active == nil then
                first_active = selected
            end
            if state.signal == "system_error" and system_error_active == nil then
                system_error_active = selected
            end
        end
    end

    if first_manual ~= nil then
        if first_manual.signal == "connection_incoming" and system_error_manual ~= nil then
            return system_error_manual
        end

        return first_manual
    end

    if first_active ~= nil and first_active.signal == "connection_incoming" and system_error_active ~= nil then
        return system_error_active
    end

    return first_active
end

---@param runtime table?
---@param bindings SgcAlarmSpeakerBinding[]
---@param signals table<string, boolean>
---@return table[]
function speaker.snapshot(runtime, bindings, signals)
    local entries = {}
    local states = binding_states(runtime, bindings or {}, signals or {})
    local selected = select_binding(states)

    for _, state in ipairs(states) do
        entries[#entries + 1] = {
            binding_key = state.binding_key,
            driver = "speaker",
            signal = state.signal,
            pattern = state.pattern,
            active = state.active,
            natural_active = state.source_active,
            override_active = state.override_active,
            selected = selected ~= nil and selected.index == state.index or false,
            mode = "steady",
        }
    end

    return entries
end

---@param runtime table
---@param binding_key_value string
---@param active boolean
---@param natural_active boolean
function speaker.set_override(runtime, binding_key_value, active, natural_active)
    if type(runtime) ~= "table" or type(binding_key_value) ~= "string" then
        return
    end

    local overrides = ensure_overrides(runtime)
    if active == natural_active then
        overrides[binding_key_value] = nil
        return
    end

    overrides[binding_key_value] = active == true
end

---@param runtime table
---@param binding_key_value string
---@param current_active boolean
---@param natural_active boolean
---@return boolean
function speaker.toggle_override(runtime, binding_key_value, current_active, natural_active)
    local next_active = current_active ~= true
    speaker.set_override(runtime, binding_key_value, next_active, natural_active)
    return next_active
end

---@param runtime table
---@param selected table
---@return boolean
local function binding_changed(runtime, selected)
    return runtime.active_binding_index ~= selected.index
        or runtime.active_signal ~= selected.signal
        or runtime.active_pattern ~= selected.pattern
end

---@param runtime table
---@param signals table<string, boolean>
---@return SgcResult
function speaker.update(runtime, signals)
    local states = binding_states(runtime, runtime.bindings or {}, signals)
    local selected = select_binding(states)
    if selected == nil then
        if runtime.active then
            local cleared = speaker.clear_runtime(runtime)
            if not cleared.ok then
                return cleared
            end
        end

        reset_runtime(runtime)
        return result.ok({
            playing = false,
        })
    end

    local pattern = PATTERNS[selected.pattern]
    if type(pattern) ~= "table" or #pattern == 0 then
        return result.err("unsupported_alarm_speaker_pattern", {
            pattern = selected.pattern,
        })
    end

    if binding_changed(runtime, selected) then
        if runtime.active then
            local cleared = speaker.clear_runtime(runtime)
            if not cleared.ok then
                return cleared
            end
        end

        runtime.active = false
        runtime.active_binding_index = selected.index
        runtime.active_signal = selected.signal
        runtime.active_pattern = selected.pattern
        runtime.step_index = 1
        runtime.next_play_at = 0
    end

    local now = time.now_ms()
    if runtime.next_play_at ~= nil and runtime.next_play_at > now then
        runtime.active = true
        return result.ok({
            playing = true,
            throttled = true,
            signal = selected.signal,
            pattern = selected.pattern,
        })
    end

    local step = pattern[runtime.step_index] or pattern[1]
    local resolved = resolve_runtime_speakers(runtime)
    if not resolved.ok then
        return resolved
    end

    if #resolved.value == 0 then
        runtime.active = false
        runtime.active_binding_index = selected.index
        runtime.active_signal = selected.signal
        runtime.active_pattern = selected.pattern
        runtime.step_index = 1
        runtime.next_play_at = 0
        return result.ok({
            playing = false,
            signal = selected.signal,
            pattern = selected.pattern,
            unavailable = true,
        })
    end

    local any_played = false
    for _, speaker_device in ipairs(resolved.value) do
        local ok, played = pcall(
            speaker_device.peripheral.playNote,
            step.instrument,
            step.volume,
            step.pitch
        )
        if not ok then
            invalidate_resolved_speakers(runtime)
            return result.err("speaker_play_failed", {
                speaker_id = speaker_device.id,
                cause = tostring(played),
            })
        end
        if played == true then
            any_played = true
        end
    end

    runtime.active = true
    runtime.active_binding_index = selected.index
    runtime.active_signal = selected.signal
    runtime.active_pattern = selected.pattern
    runtime.next_play_at = now + step.delay_ms
    runtime.step_index = runtime.step_index % #pattern + 1

    return result.ok({
        playing = any_played,
        signal = selected.signal,
        pattern = selected.pattern,
        step_index = runtime.step_index,
    })
end

return speaker
