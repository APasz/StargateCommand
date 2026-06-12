local result = require("core.result")

local planner = {}

---@param files SgcUpdateManifestFile[]
---@return table<string, SgcUpdateManifestFile>
local function index_manifest_files(files)
    local indexed = {}
    for _, file_record in ipairs(files) do
        indexed[file_record.path] = file_record
    end
    return indexed
end

---@param local_files table<string, { exists: boolean, size: integer? }>
---@param file_path string
---@return boolean
local function is_local_file_current(local_files, file_path)
    local entry = local_files[file_path]
    return entry ~= nil and entry.exists == true
end

---@param manifest SgcUpdateManifest
---@param state SgcUpdateState?
---@param local_files table<string, { exists: boolean, size: integer? }>
---@return SgcResult
function planner.build_sync_plan(manifest, state, local_files)
    local manifest_index = index_manifest_files(manifest.files)
    local state_files = state ~= nil and state.files or {}

    local downloads = {}
    local deletes = {}

    for _, file_record in ipairs(manifest.files) do
        local local_entry = local_files[file_record.path]
        local state_entry = state_files[file_record.path]
        local matches_local_size = local_entry ~= nil and local_entry.exists == true and local_entry.size == file_record.size
        local matches_state_hash = state_entry ~= nil
            and state_entry.size == file_record.size
            and state_entry.sha256 == file_record.sha256

        if not matches_local_size then
            downloads[#downloads + 1] = file_record
        elseif state == nil then
            downloads[#downloads + 1] = file_record
        elseif state.channel ~= manifest.channel then
            downloads[#downloads + 1] = file_record
        elseif state.revision == manifest.revision and matches_state_hash then
            -- Current file tracked by the same revision and size.
        elseif matches_state_hash then
            -- File content matches the last applied state, so it does not need a re-download.
        else
            downloads[#downloads + 1] = file_record
        end
    end

    for file_path, local_entry in pairs(local_files) do
        if local_entry.exists == true and manifest_index[file_path] == nil then
            deletes[#deletes + 1] = file_path
        end
    end

    table.sort(deletes)
    table.sort(downloads, function(left, right)
        return left.path < right.path
    end)

    return result.ok({
        revision_matches = state ~= nil and state.channel == manifest.channel and state.revision == manifest.revision or false,
        downloads = downloads,
        deletes = deletes,
        has_changes = #downloads > 0 or #deletes > 0,
        files_current = #downloads == 0 and #deletes == 0,
        local_files_present = next(local_files) ~= nil,
    })
end

---@param manifest SgcUpdateManifest
---@return SgcUpdateState
function planner.build_state(manifest)
    local files = {}
    for _, file_record in ipairs(manifest.files) do
        files[file_record.path] = {
            size = file_record.size,
            sha256 = file_record.sha256,
        }
    end

    return {
        schema = 1,
        channel = manifest.channel,
        revision = manifest.revision,
        managed_paths = manifest.managed_paths,
        files = files,
    }
end

return planner
