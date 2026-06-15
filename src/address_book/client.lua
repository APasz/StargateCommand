local debug_dump = require("address_book.debug_dump")
local address_book_message = require("address_book.message")
local address_book_network = require("address_book.network")
local constants = require("core.constants")
local result = require("core.result")
local store = require("address_book.store")
local transport = require("net.rednet_transport")

local client = {}

---@param config table
---@param state table
local function dump_snapshot(config, state)
    debug_dump.save_snapshot(config, state)
end

---@param config table
---@return string?
local function resolve_transport_side(config)
    if config.role == "site_controller" and config.modems ~= nil and config.modems.intersite ~= nil then
        return config.modems.intersite
    end

    if config.modems ~= nil then
        return config.modems.site
    end

    return nil
end

---@param config table
---@return SgcRole
local function resolve_target_role(config)
    if config.role == "site_controller" then
        return "address_book"
    end

    return "site_controller"
end

---@param config table
---@return SgcResult
function client.load_cached(config)
    local path = config.address_book and config.address_book.cache_path or constants.DEFAULT_ADDRESS_BOOK_CACHE_PATH
    return store.load(path)
end

---@param config table
---@param book SgcAddressBook
---@return SgcResult
function client.save_cached(config, book)
    local path = config.address_book and config.address_book.cache_path or constants.DEFAULT_ADDRESS_BOOK_CACHE_PATH
    return store.save(path, book)
end

---@param config table
---@return SgcResult
function client.fetch_remote(config)
    local transport_side = resolve_transport_side(config)
    local opened = transport.open(transport_side)
    if not opened.ok then
        dump_snapshot(config, {
            status = "unavailable",
            source = "remote",
            error = opened.error,
            details = opened.details,
        })
        return opened
    end

    local request = address_book_network.broadcast_request(
        config,
        address_book_message.build_get_book_request(
            config.address_book.server_site,
            resolve_target_role(config)
        )
    )
    if not request.ok then
        dump_snapshot(config, {
            status = "unavailable",
            source = "remote",
            error = request.error,
            details = request.details,
        })
        return request
    end

    local received = address_book_network.wait_for_result(config, request.value.msg_id, constants.DEFAULT_COMMAND_TIMEOUT_SECONDS)
    if not received.ok then
        dump_snapshot(config, {
            status = "unavailable",
            source = "remote",
            error = received.error,
            details = received.details,
        })
        return received
    end

    local validated = address_book_message.validate_book_result(received.value.envelope.payload)
    if not validated.ok then
        dump_snapshot(config, {
            status = "unavailable",
            source = "remote",
            error = validated.error,
            details = validated.details,
        })
        return validated
    end

    if validated.value.ok ~= true then
        dump_snapshot(config, {
            status = "unavailable",
            source = "remote",
            error = validated.value.error,
            details = validated.value.details,
        })
        return result.err(validated.value.error, validated.value.details)
    end

    local saved = client.save_cached(config, validated.value.book)
    if not saved.ok then
        dump_snapshot(config, {
            status = "available",
            source = "remote",
            fetched_remote = true,
            cache_loaded = false,
            error = saved.error,
            details = saved.details,
            book = validated.value.book,
        })
        return saved
    end

    dump_snapshot(config, {
        status = "available",
        source = "remote",
        fetched_remote = true,
        cache_loaded = false,
        book = validated.value.book,
    })
    return result.ok(validated.value.book)
end

---@param config table
---@return SgcResult
function client.start(config)
    if config.address_book.mode == "disabled" then
        dump_snapshot(config, {
            status = "disabled",
            source = "disabled",
        })
        return result.ok({
            mode = "disabled",
            availability = "disabled",
        })
    end

    if config.address_book.server_site ~= nil then
        local fetched = client.fetch_remote(config)
        if fetched.ok then
            dump_snapshot(config, {
                status = "available",
                source = "remote",
                fetched_remote = true,
                cache_loaded = false,
                book = fetched.value,
            })
            return result.ok({
                mode = "client",
                availability = "available",
                cache_loaded = false,
                fetched_remote = true,
                book = fetched.value,
            })
        end

        local cached = client.load_cached(config)
        if cached.ok then
            dump_snapshot(config, {
                status = "available",
                source = "cache_fallback",
                fetched_remote = false,
                cache_loaded = true,
                fetch_error = fetched.error,
                fetch_details = fetched.details,
                book = cached.value,
            })
            return result.ok({
                mode = "client",
                availability = "degraded",
                cache_loaded = true,
                fetched_remote = false,
                fetch_error = fetched.error,
                fetch_details = fetched.details,
                book = cached.value,
            })
        end

        dump_snapshot(config, {
            status = "unavailable",
            source = "remote",
            fetched_remote = false,
            cache_loaded = false,
            error = "address_book_unavailable",
            details = {
                source = "remote",
                fetch_error = fetched.error,
                fetch_details = fetched.details,
                cache_error = cached.error,
                cache_details = cached.details,
            },
        })
        return result.err("address_book_unavailable", {
            source = "remote",
            fetch_error = fetched.error,
            fetch_details = fetched.details,
            cache_error = cached.error,
            cache_details = cached.details,
        })
    end

    local cached = client.load_cached(config)
    if cached.ok then
        dump_snapshot(config, {
            status = "available",
            source = "cache",
            cache_loaded = true,
            fetched_remote = false,
            book = cached.value,
        })
        return result.ok({
            mode = "client",
            availability = "available",
            cache_loaded = true,
            fetched_remote = false,
            book = cached.value,
        })
    end

    dump_snapshot(config, {
        status = "unavailable",
        source = "cache",
        cache_loaded = false,
        fetched_remote = false,
        error = "address_book_unavailable",
        details = {
            source = "cache",
            cache_error = cached.error,
            cache_details = cached.details,
        },
    })
    return result.err("address_book_unavailable", {
        source = "cache",
        cache_error = cached.error,
        cache_details = cached.details,
    })
end

return client
