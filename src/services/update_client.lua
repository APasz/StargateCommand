local constants = require("core.constants")
local result = require("core.result")
local planner = require("update.planner")
local update_schema = require("update.schema")
local update_store = require("update.store")

local update_client = {}

local NOOP_LOGGER = {
    debug = function() end,
    info = function() end,
    warn = function() end,
    error = function() end,
}

---@param path string
---@return string?
local function dirname(path)
    local normalized = path:gsub("\\", "/")
    return normalized:match("^(.*)/[^/]+$")
end

---@param raw_url string
---@return string
local function strip_trailing_slashes(raw_url)
    return (raw_url:gsub("/+$", ""))
end

---@param path string
---@return string
local function url_encode_path(path)
    return (path:gsub("[^%w%-_./]", function(character)
        return string.format("%%%02X", string.byte(character))
    end))
end

---@param path string
---@return boolean
local function path_exists(path)
    local ok, exists = pcall(fs.exists, path)
    return ok and exists == true
end

---@param path string
---@return boolean
local function is_directory(path)
    local ok, value = pcall(fs.isDir, path)
    return ok and value == true
end

---@param path string
---@return integer?
local function get_file_size(path)
    if type(fs.getSize) == "function" then
        local ok, value = pcall(fs.getSize, path)
        if ok and type(value) == "number" then
            return value
        end
    end

    local handle = fs.open(path, "rb")
    if handle == nil then
        return nil
    end

    local content = handle.readAll()
    handle.close()
    if type(content) ~= "string" then
        return nil
    end

    return #content
end

---@param path string
---@return SgcResult
local function ensure_parent_dir(path)
    local parent = dirname(path)
    if parent == nil or parent == "" then
        return result.ok(true)
    end

    if path_exists(parent) then
        if is_directory(parent) then
            return result.ok(true)
        end

        return result.err("update_parent_not_directory", {
            path = path,
            parent = parent,
        })
    end

    local ok, create_error = pcall(fs.makeDir, parent)
    if not ok then
        return result.err("update_parent_create_failed", {
            path = path,
            parent = parent,
            cause = tostring(create_error),
        })
    end

    return result.ok(true)
end

---@param path string
---@param content string
---@return SgcResult
local function write_binary_file(path, content)
    local parent_result = ensure_parent_dir(path)
    if not parent_result.ok then
        return parent_result
    end

    local handle = fs.open(path, "wb")
    if handle == nil then
        return result.err("update_write_open_failed", {
            path = path,
        })
    end

    handle.write(content)
    handle.close()
    return result.ok(true)
end

---@param path string
---@return SgcResult
local function delete_path(path)
    if not path_exists(path) then
        return result.ok(false)
    end

    local ok, delete_error = pcall(fs.delete, path)
    if not ok then
        return result.err("update_delete_failed", {
            path = path,
            cause = tostring(delete_error),
        })
    end

    return result.ok(true)
end

---@param path string
---@return SgcResult
local function reset_directory(path)
    local deleted = delete_path(path)
    if not deleted.ok then
        return deleted
    end

    local ok, create_error = pcall(fs.makeDir, path)
    if not ok then
        return result.err("update_temp_dir_create_failed", {
            path = path,
            cause = tostring(create_error),
        })
    end

    return result.ok(true)
end

---@param root_path string
---@param relative_path string?
---@param files table<string, { exists: boolean, size: integer? }>
---@return SgcResult
local function collect_files_recursive(root_path, relative_path, files)
    local list_result = { pcall(fs.list, root_path) }
    if not list_result[1] then
        return result.err("update_list_failed", {
            path = root_path,
            cause = tostring(list_result[2]),
        })
    end

    for _, name in ipairs(list_result[2]) do
        local absolute_path = fs.combine(root_path, name)
        local relative_child = relative_path ~= nil and fs.combine(relative_path, name) or name

        if is_directory(absolute_path) then
            local nested = collect_files_recursive(absolute_path, relative_child, files)
            if not nested.ok then
                return nested
            end
        else
            files[relative_child] = {
                exists = true,
                size = get_file_size(absolute_path),
            }
        end
    end

    return result.ok(true)
end

---@param managed_paths string[]
---@return SgcResult
local function collect_local_managed_files(managed_paths)
    local files = {}

    for _, managed_path in ipairs(managed_paths) do
        local is_managed_directory = managed_path:sub(-1) == "/"
        local normalized_path = is_managed_directory and managed_path:sub(1, -2) or managed_path

        if not path_exists(normalized_path) then
            -- Missing paths are represented by absence in the local file index.
        elseif is_managed_directory then
            if not is_directory(normalized_path) then
                return result.err("update_managed_path_not_directory", {
                    path = normalized_path,
                })
            end

            local collected = collect_files_recursive(normalized_path, normalized_path, files)
            if not collected.ok then
                return collected
            end
        else
            if is_directory(normalized_path) then
                return result.err("update_managed_path_not_file", {
                    path = normalized_path,
                })
            end

            files[normalized_path] = {
                exists = true,
                size = get_file_size(normalized_path),
            }
        end
    end

    return result.ok(files)
end

---@param payload string
---@return string?
local function compute_sha256(payload)
    if textutils ~= nil and type(textutils.sha256) == "function" then
        local ok, value = pcall(textutils.sha256, payload)
        if ok and type(value) == "string" then
            return value
        end
    end

    if type(_G.sha256) == "function" then
        local ok, value = pcall(_G.sha256, payload)
        if ok and type(value) == "string" then
            return value
        end
    end

    return nil
end

---@param url string
---@return SgcResult
local function http_get(url)
    if http == nil or type(http.get) ~= "function" then
        return result.err("http_unavailable", {
            url = url,
        })
    end

    local ok, response, response_error = pcall(http.get, url, nil, true)
    if not ok then
        return result.err("http_request_failed", {
            url = url,
            cause = tostring(response),
        })
    end

    if response == nil then
        return result.err("http_request_failed", {
            url = url,
            cause = tostring(response_error),
        })
    end

    local body = response.readAll()
    response.close()
    if type(body) ~= "string" then
        return result.err("http_read_failed", {
            url = url,
        })
    end

    return result.ok(body)
end

---@param payload string
---@return SgcResult
local function decode_json(payload)
    if textutils ~= nil and type(textutils.unserializeJSON) == "function" then
        local ok, value = pcall(textutils.unserializeJSON, payload)
        if ok and value ~= nil then
            return result.ok(value)
        end
    end

    if textutils ~= nil and type(textutils.unserialiseJSON) == "function" then
        local ok, value = pcall(textutils.unserialiseJSON, payload)
        if ok and value ~= nil then
            return result.ok(value)
        end
    end

    return result.err("json_unavailable")
end

---@param update_config SgcUpdateConfig
---@return string
local function build_manifest_url(update_config)
    return strip_trailing_slashes(update_config.base_url)
        .. "/v1/channels/"
        .. update_config.channel
        .. "/manifest.json"
end

---@param update_config SgcUpdateConfig
---@param file_path string
---@return string
local function build_file_url(update_config, file_path)
    return strip_trailing_slashes(update_config.base_url)
        .. "/v1/channels/"
        .. update_config.channel
        .. "/files/"
        .. url_encode_path(file_path)
end

---@param config table
---@return SgcUpdateConfig
local function resolve_update_config(config)
    local update = config.update or {}

    return {
        mode = update.mode or constants.DEFAULT_UPDATE_MODE,
        base_url = update.base_url or constants.DEFAULT_UPDATE_BASE_URL,
        channel = update.channel or constants.DEFAULT_UPDATE_CHANNEL,
        state_path = update.state_path or constants.DEFAULT_UPDATE_STATE_PATH,
        temp_dir = update.temp_dir or constants.DEFAULT_UPDATE_TEMP_DIR,
        auto_reboot = update.auto_reboot == true,
    }
end

---@param update_config SgcUpdateConfig
---@return SgcResult
local function load_manifest(update_config)
    local manifest_body = http_get(build_manifest_url(update_config))
    if not manifest_body.ok then
        return manifest_body
    end

    local decoded = decode_json(manifest_body.value)
    if not decoded.ok then
        if decoded.details == nil then
            decoded.details = {}
        end
        decoded.details.url = build_manifest_url(update_config)
        return decoded
    end

    local validation = update_schema.validate_manifest(decoded.value)
    if not validation.ok then
        if validation.details == nil then
            validation.details = {}
        end
        validation.details.url = build_manifest_url(update_config)
        return validation
    end

    if validation.value.channel ~= update_config.channel then
        return result.err("update_channel_mismatch", {
            expected = update_config.channel,
            actual = validation.value.channel,
        })
    end

    return validation
end

---@param update_config SgcUpdateConfig
---@param downloads SgcUpdateManifestFile[]
---@param logger table
---@return SgcResult
local function stage_downloads(update_config, downloads, logger)
    local stage_root = fs.combine(update_config.temp_dir, "files")
    local prepared = reset_directory(update_config.temp_dir)
    if not prepared.ok then
        return prepared
    end

    local downloaded = {}

    for _, file_record in ipairs(downloads) do
        local url = build_file_url(update_config, file_record.path)
        logger:debug("downloading update file", {
            path = file_record.path,
            url = url,
        })

        local body_result = http_get(url)
        if not body_result.ok then
            return body_result
        end

        if #body_result.value ~= file_record.size then
            return result.err("update_download_size_mismatch", {
                path = file_record.path,
                expected = file_record.size,
                actual = #body_result.value,
            })
        end

        local actual_sha256 = compute_sha256(body_result.value)
        if actual_sha256 ~= nil and actual_sha256 ~= file_record.sha256 then
            return result.err("update_download_hash_mismatch", {
                path = file_record.path,
                expected = file_record.sha256,
                actual = actual_sha256,
            })
        end

        local stage_path = fs.combine(stage_root, file_record.path)
        local written = write_binary_file(stage_path, body_result.value)
        if not written.ok then
            return written
        end

        downloaded[#downloaded + 1] = {
            path = file_record.path,
            stage_path = stage_path,
        }
    end

    return result.ok(downloaded)
end

---@param staged_files table[]
---@param deletes string[]
---@return SgcResult
local function apply_staged_files(staged_files, deletes)
    for _, file_path in ipairs(deletes) do
        local deleted = delete_path(file_path)
        if not deleted.ok then
            return deleted
        end
    end

    for _, staged_file in ipairs(staged_files) do
        local ensured = ensure_parent_dir(staged_file.path)
        if not ensured.ok then
            return ensured
        end

        if path_exists(staged_file.path) then
            local deleted = delete_path(staged_file.path)
            if not deleted.ok then
                return deleted
            end
        end

        local ok, move_error = pcall(fs.move, staged_file.stage_path, staged_file.path)
        if not ok then
            return result.err("update_move_failed", {
                from = staged_file.stage_path,
                to = staged_file.path,
                cause = tostring(move_error),
            })
        end
    end

    return result.ok(true)
end

---@param update_config SgcUpdateConfig
---@param manifest SgcUpdateManifest
---@param state SgcUpdateState?
---@param logger table
---@return SgcResult
local function run_sync(update_config, manifest, state, logger)
    local local_files_result = collect_local_managed_files(manifest.managed_paths)
    if not local_files_result.ok then
        return local_files_result
    end

    local plan_result = planner.build_sync_plan(manifest, state, local_files_result.value)
    if not plan_result.ok then
        return plan_result
    end

    local plan = plan_result.value
    if not plan.has_changes then
        logger:debug("update already current", {
            channel = manifest.channel,
            revision = manifest.revision,
        })

        return result.ok({
            checked = true,
            available = false,
            applied = false,
            revision = manifest.revision,
            downloads = 0,
            deletes = 0,
            reboot_required = false,
            hash_verified = false,
        })
    end

    logger:info("update available", {
        channel = manifest.channel,
        revision = manifest.revision,
        downloads = #plan.downloads,
        deletes = #plan.deletes,
    })

    if update_config.mode == "notify" then
        return result.ok({
            checked = true,
            available = true,
            applied = false,
            revision = manifest.revision,
            downloads = #plan.downloads,
            deletes = #plan.deletes,
            reboot_required = false,
            hash_verified = false,
        })
    end

    local staged = stage_downloads(update_config, plan.downloads, logger)
    if not staged.ok then
        return staged
    end

    local applied = apply_staged_files(staged.value, plan.deletes)
    if not applied.ok then
        return applied
    end

    local state_result = update_store.save(update_config.state_path, planner.build_state(manifest))
    if not state_result.ok then
        return state_result
    end

    delete_path(update_config.temp_dir)

    return result.ok({
        checked = true,
        available = true,
        applied = true,
        revision = manifest.revision,
        downloads = #plan.downloads,
        deletes = #plan.deletes,
        reboot_required = true,
        hash_verified = compute_sha256("probe") ~= nil,
    })
end

---@param logger table?
---@return table
local function normalize_logger(logger)
    if logger == nil then
        return NOOP_LOGGER
    end

    return logger
end

---@param config table
---@param logger table?
---@return SgcResult
local function execute_update(config, logger)
    local update_config = resolve_update_config(config)
    local active_logger = normalize_logger(logger)

    if update_config.mode == "disabled" then
        return result.ok({
            checked = false,
            available = false,
            applied = false,
            revision = nil,
            downloads = 0,
            deletes = 0,
            reboot_required = false,
            hash_verified = false,
        })
    end

    if fs == nil
        or type(fs.exists) ~= "function"
        or type(fs.isDir) ~= "function"
        or type(fs.list) ~= "function"
        or type(fs.open) ~= "function"
        or type(fs.makeDir) ~= "function"
        or type(fs.move) ~= "function"
        or type(fs.delete) ~= "function"
    then
        return result.err("filesystem_unavailable")
    end

    local loaded_state = update_store.load_optional(update_config.state_path)
    if not loaded_state.ok then
        return loaded_state
    end

    local manifest = load_manifest(update_config)
    if not manifest.ok then
        return manifest
    end

    return run_sync(update_config, manifest.value, loaded_state.value, active_logger)
end

---@param config table
---@param logger table?
---@return SgcResult
function update_client.preflight(config, logger)
    local sync_result = execute_update(config, logger)
    if not sync_result.ok then
        return sync_result
    end

    local details = sync_result.value
    if details.applied and resolve_update_config(config).auto_reboot and os ~= nil and type(os.reboot) == "function" then
        normalize_logger(logger):warn("rebooting after update", {
            revision = details.revision,
        })
        os.reboot()
        details.reboot_requested = true
    end

    return sync_result
end

---@param config table
---@param logger table?
---@return SgcResult
function update_client.start(config, logger)
    return execute_update(config, logger)
end

return update_client
