local console = require("address_book.console")
local debug_dump = require("address_book.debug_dump")
local address_book_message = require("address_book.message")
local address_book_network = require("address_book.network")
local constants = require("core.constants")
local discovery = require("net.discovery")
local host_lifecycle = require("lifecycle.host")
local net_inbox = require("net.inbox")
local log_messages = require("core.log_messages")
local result = require("core.result")
local store = require("address_book.store")
local transport = require("net.rednet_transport")

local server = {}
local NOOP_LOGGER = {
    debug = function() end,
    info = function() end,
    warn = function() end,
    error = function() end,
}

---@param config table
---@return string
local function resolve_server_path(config)
    if config.address_book ~= nil and type(config.address_book.server_path) == "string" then
        return config.address_book.server_path
    end

    return constants.DEFAULT_ADDRESS_BOOK_SERVER_PATH
end

---@param config table
---@return SgcResult
function server.start(config)
    local path = resolve_server_path(config)
    local loaded = store.load(path)
    local bootstrap_on_missing = config.address_book ~= nil and config.address_book.bootstrap_on_missing == true

    if loaded.ok then
        local source = "server_file"
        if loaded.details ~= nil and loaded.details.migrated == true then
            local migrated = store.save(path, loaded.value)
            if not migrated.ok then
                return migrated
            end
            source = "server_migrated"
        end

        debug_dump.save_snapshot(config, {
            status = "available",
            source = source,
            path = path,
            book = loaded.value,
        })
        return result.ok({
            mode = "server",
            path = path,
            book = loaded.value,
            inbox = net_inbox.new(),
        })
    end

    local missing_source = loaded.error == "address_book_load_failed"
        and type(loaded.details) == "table"
        and loaded.details.cause == "address_book_missing"

    if missing_source and bootstrap_on_missing then
        local default_book = store.default_book()
        local saved = store.save(path, default_book)
        if not saved.ok then
            return saved
        end

        debug_dump.save_snapshot(config, {
            status = "available",
            source = "server_bootstrap",
            path = path,
            book = default_book,
        })
        return result.ok({
            mode = "server",
            path = path,
            book = default_book,
            inbox = net_inbox.new(),
        })
    end

    debug_dump.save_snapshot(config, {
        status = "unavailable",
        source = "server_error",
        path = path,
        error = loaded.error,
        details = loaded.details,
    })
    return loaded
end

---@param config table
---@return string?
local function resolve_transport_side(config)
    if config.modems ~= nil and config.modems.intersite ~= nil then
        return config.modems.intersite
    end

    if config.modems ~= nil then
        return config.modems.site
    end

    return nil
end

---@param logger table?
---@return table
local function normalize_logger(logger)
    return logger or NOOP_LOGGER
end

---@param config table
---@param runtime table
---@param incoming table
---@return SgcResult
function server.handle_request(config, runtime, incoming)
    local lifecycle_handled = host_lifecycle.handle_command(config, incoming, nil, {
        before_reboot = function(intent)
            if type(print) == "function" then
                print("Host restarting" .. (intent.reason ~= nil and ": " .. tostring(intent.reason) or ""))
            end
            return result.ok(true)
        end,
    })
    if not lifecycle_handled.ok then
        return lifecycle_handled
    end

    if type(lifecycle_handled.value) == "table" and lifecycle_handled.value.handled == true then
        return lifecycle_handled
    end

    if incoming.envelope.type ~= "addressbook" then
        return result.ok({
            handled = false,
        })
    end

    if not address_book_message.is_targeted_request(incoming.envelope.payload, config.role, config.site) then
        return result.ok({
            handled = false,
        })
    end

    local validated = address_book_message.validate_get_book_request(incoming.envelope.payload)
    local request_id = type(incoming.envelope.payload.request_id) == "string" and incoming.envelope.payload.request_id
        or incoming.envelope.msg_id
    local response_payload = nil
    if not validated.ok then
        response_payload =
            address_book_message.build_book_result(request_id, result.err(validated.error, validated.details))
    else
        response_payload = address_book_message.build_book_result(request_id, result.ok(runtime.book))
    end

    return address_book_network.send_result(config, incoming.sender_id, incoming.envelope, response_payload)
end

---@param config table
---@param logger table?
---@return SgcResult
function server.serve(config, logger)
    local active_logger = normalize_logger(logger)
    local started = server.start(config)
    if not started.ok then
        return started
    end

    local transport_side = resolve_transport_side(config)
    local opened = transport.open(transport_side)
    if not opened.ok then
        return opened
    end

    active_logger:info(log_messages.ready())
    local announced = discovery.announce(config, {
        services = { config.role },
    })
    if not announced.ok then
        active_logger:warn("failed to broadcast hello", announced.details)
    end

    local function serve_requests()
        while true do
            local received = net_inbox.receive_next(config, started.value.inbox, nil, nil, active_logger)
            if not received.ok then
                active_logger:error("address book receive failed", {
                    error = received.error,
                    details = received.details,
                })
                return received
            end

            local handled = server.handle_request(config, started.value, received.value)
            if not handled.ok then
                active_logger:error("address book request handling failed", {
                    error = handled.error,
                    details = handled.details,
                })
            elseif type(handled.value) == "table" and handled.value.handled == false then
                active_logger:debug("ignoring unrelated address book envelope", {
                    msg_id = received.value.envelope.msg_id,
                    protocol = received.value.protocol,
                    role = received.value.envelope.role,
                })
            end
        end
    end

    if parallel ~= nil
        and type(parallel.waitForAny) == "function"
        and type(read) == "function"
        and os ~= nil
        and type(os.pullEvent) == "function"
    then
        local exited = nil
        parallel.waitForAny(
            function()
                exited = serve_requests()
            end,
            function()
                console.run(config, started.value, active_logger)
            end
        )

        return exited or result.err("address_book_server_stopped")
    end

    return serve_requests()
end

return server
