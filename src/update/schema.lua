local constants = require("core.constants")
local result = require("core.result")
local validate = require("core.validate")

local schema = {}

---@param path string
---@return boolean
local function is_relative_file_path(path)
    if type(path) ~= "string" or path == "" then
        return false
    end

    if path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil then
        return false
    end

    if path:sub(-1) == "/" then
        return false
    end

    for segment in path:gmatch("[^/]+") do
        if segment == "." or segment == ".." or segment == "" then
            return false
        end
    end

    return true
end

---@param path string
---@return boolean
local function is_relative_managed_path(path)
    if type(path) ~= "string" or path == "" then
        return false
    end

    if path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil then
        return false
    end

    local normalized = path
    if normalized:sub(-1) == "/" then
        normalized = normalized:sub(1, -2)
    end

    if normalized == "" then
        return false
    end

    for segment in normalized:gmatch("[^/]+") do
        if segment == "." or segment == ".." or segment == "" then
            return false
        end
    end

    return true
end

---@param errors table[]
---@param path string
---@param value any
---@return boolean
local function expect_hex_sha256(errors, path, value)
    if not validate.expect_string(errors, path, value, false) then
        return false
    end

    if value:match("^[0-9a-f]+$") == nil or #value ~= 64 then
        validate.push_error(errors, path, "expected lowercase sha256 hex")
        return false
    end

    return true
end

---@param manifest any
---@return SgcResult
function schema.validate_manifest(manifest)
    local errors = {}

    if not validate.expect_table(errors, "manifest", manifest) then
        return validate.result(errors)
    end

    validate.expect_integer(errors, "manifest.schema", manifest.schema)
    if manifest.schema ~= constants.UPDATE_MANIFEST_SCHEMA_VERSION then
        validate.push_error(errors, "manifest.schema", "unsupported update manifest schema")
    end

    if validate.expect_string(errors, "manifest.channel", manifest.channel, false) then
        if not validate.is_site_id(manifest.channel) then
            validate.push_error(errors, "manifest.channel", "invalid update channel")
        end
    end

    validate.expect_string(errors, "manifest.source_kind", manifest.source_kind, false)
    validate.expect_string(errors, "manifest.revision", manifest.revision, false)
    validate.expect_string(errors, "manifest.generated_at", manifest.generated_at, false)

    if manifest.source_ref ~= nil then
        validate.expect_string(errors, "manifest.source_ref", manifest.source_ref, false)
    end

    if validate.expect_string_array(errors, "manifest.managed_paths", manifest.managed_paths) then
        for index, managed_path in ipairs(manifest.managed_paths) do
            if not is_relative_managed_path(managed_path) then
                validate.push_error(
                    errors,
                    "manifest.managed_paths[" .. index .. "]",
                    "invalid managed path"
                )
            end
        end
    end

    local seen_paths = {}
    if validate.expect_table(errors, "manifest.files", manifest.files) then
        for index, file_record in ipairs(manifest.files) do
            if validate.expect_table(errors, "manifest.files[" .. index .. "]", file_record) then
                if validate.expect_string(errors, "manifest.files[" .. index .. "].path", file_record.path, false) then
                    if not is_relative_file_path(file_record.path) then
                        validate.push_error(
                            errors,
                            "manifest.files[" .. index .. "].path",
                            "invalid file path"
                        )
                    elseif seen_paths[file_record.path] then
                        validate.push_error(
                            errors,
                            "manifest.files[" .. index .. "].path",
                            "duplicate file path"
                        )
                    else
                        seen_paths[file_record.path] = true
                    end
                end

                validate.expect_integer(errors, "manifest.files[" .. index .. "].size", file_record.size)
                if file_record.size ~= nil and file_record.size < 0 then
                    validate.push_error(errors, "manifest.files[" .. index .. "].size", "expected non-negative integer")
                end

                expect_hex_sha256(errors, "manifest.files[" .. index .. "].sha256", file_record.sha256)
            end
        end
    end

    local validation = validate.result(errors)
    if not validation.ok then
        return validation
    end

    return result.ok(manifest)
end

---@param state any
---@return SgcResult
function schema.validate_state(state)
    local errors = {}

    if not validate.expect_table(errors, "state", state) then
        return validate.result(errors)
    end

    validate.expect_integer(errors, "state.schema", state.schema)
    if state.schema ~= constants.UPDATE_STATE_SCHEMA_VERSION then
        validate.push_error(errors, "state.schema", "unsupported update state schema")
    end

    if validate.expect_string(errors, "state.channel", state.channel, false) then
        if not validate.is_site_id(state.channel) then
            validate.push_error(errors, "state.channel", "invalid update channel")
        end
    end

    validate.expect_string(errors, "state.revision", state.revision, false)

    if validate.expect_string_array(errors, "state.managed_paths", state.managed_paths) then
        for index, managed_path in ipairs(state.managed_paths) do
            if not is_relative_managed_path(managed_path) then
                validate.push_error(errors, "state.managed_paths[" .. index .. "]", "invalid managed path")
            end
        end
    end

    if validate.expect_table(errors, "state.files", state.files) then
        for file_path, file_record in pairs(state.files) do
            if not is_relative_file_path(file_path) then
                validate.push_error(errors, "state.files", "invalid file key: " .. tostring(file_path))
            elseif validate.expect_table(errors, "state.files." .. file_path, file_record) then
                validate.expect_integer(errors, "state.files." .. file_path .. ".size", file_record.size)
                if file_record.size ~= nil and file_record.size < 0 then
                    validate.push_error(
                        errors,
                        "state.files." .. file_path .. ".size",
                        "expected non-negative integer"
                    )
                end
                expect_hex_sha256(errors, "state.files." .. file_path .. ".sha256", file_record.sha256)
            end
        end
    end

    local validation = validate.result(errors)
    if not validation.ok then
        return validation
    end

    return result.ok(state)
end

return schema
