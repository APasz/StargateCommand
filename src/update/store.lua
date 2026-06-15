local constants = require("core.constants")
local persistence = require("core.persistence")
local result = require("core.result")
local schema = require("update.schema")

local store = {}

---@param path string
---@return SgcResult
function store.load_optional(path)
    if not persistence.exists(path) then
        return result.ok(nil)
    end

    local loaded = persistence.load_serialized_table(path)
    if not loaded.ok then
        return result.err("update_state_load_failed", {
            path = path,
            cause = loaded.error,
            details = loaded.details,
        })
    end

    local validation = schema.validate_state(loaded.value)
    if not validation.ok then
        if validation.details == nil then
            validation.details = {}
        end
        validation.details.path = path
        return validation
    end

    return validation
end

---@param path string
---@param state SgcUpdateState
---@return SgcResult
function store.save(path, state)
    local validation = schema.validate_state(state)
    if not validation.ok then
        return validation
    end

    local saved = persistence.save_serialized_table(path, validation.value)
    if not saved.ok then
        return result.err("update_state_save_failed", {
            path = path,
            cause = saved.error,
            details = saved.details,
        })
    end

    return result.ok(true, {
        path = path,
        schema = constants.UPDATE_STATE_SCHEMA_VERSION,
    })
end

return store
