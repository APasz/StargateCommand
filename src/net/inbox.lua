local result = require("core.result")
local time = require("core.time")
local transport = require("net.rednet_transport")

local inbox = {}

local NOOP_LOGGER = {
    debug = function() end,
}

---@param logger table?
---@return table
local function normalize_logger(logger)
    return logger or NOOP_LOGGER
end

---@param state table?
---@return table
local function entries(state)
    if type(state) ~= "table" then
        return {}
    end

    state.messages = state.messages or {}
    return state.messages
end

---@param state table
---@param deferred_messages table[]
local function restore_deferred_messages(state, deferred_messages)
    if #deferred_messages == 0 then
        return
    end

    local queued = entries(state)
    local restored = {}

    for _, incoming in ipairs(deferred_messages) do
        restored[#restored + 1] = incoming
    end

    for _, incoming in ipairs(queued) do
        restored[#restored + 1] = incoming
    end

    state.messages = restored
end

---@param timeout_seconds number?
---@param started_at integer
---@return number?
local function remaining_timeout(timeout_seconds, started_at)
    if timeout_seconds == nil then
        return nil
    end

    local elapsed_seconds = (time.now_ms() - started_at) / 1000
    local timeout = timeout_seconds - elapsed_seconds
    if timeout <= 0 then
        return 0
    end

    return timeout
end

---@param logger table?
---@param operation SgcResult
local function log_ignored_receive(logger, operation)
    normalize_logger(logger):debug("ignoring invalid inbound message", {
        error = operation.error,
        details = operation.details,
    })
end

---@param options table
---@return SgcResult
local function run_before_receive(options)
    local hook = type(options) == "table" and options.before_receive or nil
    if type(hook) ~= "function" then
        return result.ok(false)
    end

    local checked = hook()
    if result.is_result(checked) then
        return checked
    end

    return result.ok(checked)
end

---@param timeout number?
---@param poll_interval_seconds number?
---@return number?
local function receive_timeout(timeout, poll_interval_seconds)
    if type(poll_interval_seconds) ~= "number" or poll_interval_seconds <= 0 then
        return timeout
    end

    if timeout == nil or timeout > poll_interval_seconds then
        return poll_interval_seconds
    end

    return timeout
end

---@return table
function inbox.new()
    return {
        messages = {},
    }
end

---@param state table
---@param incoming table
function inbox.push(state, incoming)
    local queued = entries(state)
    queued[#queued + 1] = incoming
end

---@param state table
---@return table?
function inbox.shift(state)
    local queued = entries(state)
    if #queued == 0 then
        return nil
    end

    return table.remove(queued, 1)
end

---@param state table
---@param predicate fun(incoming: table): boolean
---@return table?
function inbox.pop_matching(state, predicate)
    local queued = entries(state)
    for index, incoming in ipairs(queued) do
        if predicate(incoming) then
            return table.remove(queued, index)
        end
    end

    return nil
end

---@param config table
---@param state table
---@param timeout_seconds number?
---@param accepted_protocols string[]?
---@param logger table?
---@param options table?
---@return SgcResult
function inbox.receive_next(config, state, timeout_seconds, accepted_protocols, logger, options)
    local active_options = type(options) == "table" and options or {}
    local checked = run_before_receive(active_options)
    if not checked.ok then
        return checked
    end

    local queued = inbox.shift(state)
    if queued ~= nil then
        return result.ok(queued)
    end

    local started_at = time.now_ms()
    while true do
        checked = run_before_receive(active_options)
        if not checked.ok then
            return checked
        end

        local timeout = remaining_timeout(timeout_seconds, started_at)
        if timeout_seconds ~= nil and timeout == 0 then
            return result.err("receive_timeout")
        end

        local next_timeout = receive_timeout(timeout, active_options.poll_interval_seconds)
        local received = transport.receive(config, next_timeout, accepted_protocols)
        if received.ok then
            return received
        end

        if received.error == "receive_timeout" then
            if next_timeout == timeout then
                return received
            end
        elseif transport.is_nonfatal_receive_error(received.error) then
            log_ignored_receive(logger, received)
        else
            return received
        end
    end
end

---@param config table
---@param state table
---@param timeout_seconds number?
---@param accepted_protocols string[]?
---@param predicate fun(incoming: table): boolean
---@param logger table?
---@param on_unmatched fun(incoming: table): SgcResult?
---@param options table?
---@return SgcResult
function inbox.wait_for_match(config, state, timeout_seconds, accepted_protocols, predicate, logger, on_unmatched, options)
    local active_options = type(options) == "table" and options or {}
    local checked = run_before_receive(active_options)
    if not checked.ok then
        return checked
    end

    local matched = inbox.pop_matching(state, predicate)
    if matched ~= nil then
        return result.ok(matched)
    end

    local started_at = time.now_ms()
    local deferred_messages = {}
    while true do
        local timeout = remaining_timeout(timeout_seconds, started_at)
        if timeout_seconds ~= nil and timeout == 0 then
            restore_deferred_messages(state, deferred_messages)
            return result.err("receive_timeout")
        end

        local received = inbox.receive_next(config, state, timeout, accepted_protocols, logger, active_options)
        if not received.ok then
            restore_deferred_messages(state, deferred_messages)
            return received
        end

        local incoming = received.value
        if predicate(incoming) then
            restore_deferred_messages(state, deferred_messages)
            return result.ok(incoming)
        end

        local consumed = false
        if type(on_unmatched) == "function" then
            local handled = on_unmatched(incoming)
            if not handled.ok then
                restore_deferred_messages(state, deferred_messages)
                return handled
            end

            consumed = handled.value == true
        end

        if not consumed then
            deferred_messages[#deferred_messages + 1] = incoming
        end
    end
end

return inbox
