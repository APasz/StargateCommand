local version = {}

local DEFAULT_SHORT_REVISION_LENGTH = 7
local DEV_SHORT_REVISION_LENGTH = 3

---@param revision string?
---@param length integer
---@return string?
local function short_revision(revision, length)
    if type(revision) ~= "string" or revision == "" then
        return nil
    end

    if #revision <= length then
        return revision
    end

    return revision:sub(1, length)
end

---@param channel string?
---@param revision string?
---@param display_version string?
---@return string?
function version.resolve_display_version(channel, revision, display_version)
    if type(display_version) == "string" and display_version ~= "" then
        return display_version
    end

    if channel == "stable" then
        local short = short_revision(revision, DEFAULT_SHORT_REVISION_LENGTH)
        return short ~= nil and ("B-local-" .. short) or nil
    end

    if channel == "dev" then
        local short = short_revision(revision, DEV_SHORT_REVISION_LENGTH)
        return short ~= nil and ("D" .. short) or nil
    end

    local short = short_revision(revision, DEFAULT_SHORT_REVISION_LENGTH)
    if short == nil then
        return nil
    end

    if type(channel) == "string" and channel ~= "" then
        return channel .. "@" .. short
    end

    return short
end

return version
