local constants = require("core.constants")
local persistence = require("core.persistence")
local result = require("core.result")

local debug_dump = {}

---@return integer?
local function current_time()
    if type(os) == "table" and type(os.epoch) == "function" then
        local ok, value = pcall(os.epoch, "utc")
        if ok and type(value) == "number" then
            return value
        end
    end

    if type(os) == "table" and type(os.time) == "function" then
        local ok, value = pcall(os.time)
        if ok and type(value) == "number" then
            return value
        end
    end

    return nil
end

---@param path string
---@param snapshot table
---@return SgcResult
local function write_snapshot(path, snapshot)
    local saved = persistence.save_serialized_table(path, snapshot)
    if not saved.ok then
        return result.err("address_book_debug_save_failed", {
            path = path,
            cause = saved.error,
            details = saved.details,
        })
    end

    return saved
end

---@param config table
---@param state table
---@return SgcResult
function debug_dump.save_snapshot(config, state)
    return write_snapshot(constants.DEFAULT_ADDRESS_BOOK_DEBUG_PATH, {
        schema = 1,
        dumped_at = current_time(),
        site = config.site,
        role = config.role,
        source = state.source,
        status = state.status,
        path = state.path,
        cache_loaded = state.cache_loaded,
        fetched_remote = state.fetched_remote,
        error = state.error,
        details = state.details,
        fetch_error = state.fetch_error,
        fetch_details = state.fetch_details,
        warning = state.warning,
        book = state.book,
    })
end

return debug_dump
