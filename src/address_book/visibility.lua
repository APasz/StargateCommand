local visibility = {}

---@param refs string[]?
---@param site_id string
---@return boolean
local function matches_site_or_wildcard(refs, site_id)
    if type(refs) ~= "table" then
        return false
    end

    for _, ref in ipairs(refs) do
        if ref == "*" or ref == site_id then
            return true
        end
    end

    return false
end

---@param site SgcSiteEntry
---@return string[]?
local function hidden_refs(site)
    local site_visibility = site.visibility or {}
    return site_visibility.hidden_at or site_visibility.hidden_from
end

---@param origin SgcSiteEntry
---@param destination SgcSiteEntry
---@return boolean
local function is_intergalactic(origin, destination)
    if origin.location.universe ~= destination.location.universe then
        return true
    end

    return origin.location.galaxy ~= destination.location.galaxy
end

---@param book SgcAddressBook
---@param origin_site_id string
---@param destination_site_id string
---@return boolean
function visibility.can_see(book, origin_site_id, destination_site_id)
    if origin_site_id == destination_site_id then
        return false
    end

    local sites = book and book.sites or nil
    if type(sites) ~= "table" then
        return false
    end

    local origin = sites[origin_site_id]
    local destination = sites[destination_site_id]
    if type(origin) ~= "table" or type(destination) ~= "table" then
        return false
    end

    if origin.enabled ~= true or destination.enabled ~= true then
        return false
    end

    if type(destination.visibility) ~= "table" or destination.visibility.listed ~= true then
        return false
    end

    if matches_site_or_wildcard(hidden_refs(destination), origin_site_id) then
        return false
    end

    if destination.visibility.visible_from ~= nil and not matches_site_or_wildcard(
        destination.visibility.visible_from,
        origin_site_id
    ) then
        return false
    end

    if is_intergalactic(origin, destination) then
        return matches_site_or_wildcard(destination.visibility.intergalactic, origin_site_id)
    end

    return true
end

return visibility

