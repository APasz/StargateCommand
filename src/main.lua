local constants = require("core.constants")
local result = require("core.result")

local main = {}

---@param role SgcRole
---@return SgcResult
local function load_app(role)
    local module_name = constants.APP_MODULES[role]
    if module_name == nil then
        return result.err("unknown_role", {
            role = role,
        })
    end

    local ok, app_module = pcall(require, module_name)
    if not ok then
        return result.err("app_load_failed", {
            role = role,
            module = module_name,
            cause = tostring(app_module),
        })
    end

    if type(app_module) ~= "table" or type(app_module.run) ~= "function" then
        return result.err("app_missing_run", {
            role = role,
            module = module_name,
        })
    end

    return result.ok(app_module)
end

---@param config table
---@return SgcResult
function main.run(config)
    local loaded = load_app(config.role)
    if not loaded.ok then
        return loaded
    end

    local ok, app_result = pcall(loaded.value.run, config)
    if not ok then
        return result.err("app_crashed", {
            role = config.role,
            cause = tostring(app_result),
        })
    end

    if result.is_result(app_result) then
        return app_result
    end

    return result.ok(app_result)
end

return main

