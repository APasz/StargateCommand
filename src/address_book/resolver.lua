local visibility = require("address_book.visibility")

local resolver = {}

---@param origin SgcSiteEntry
---@param destination SgcSiteEntry
---@return SgcAddressKind[]
local function preferred_address_order(origin, destination)
    if origin.location.universe == destination.location.universe then
        if origin.location.galaxy == destination.location.galaxy then
            if origin.location.dimension == destination.location.dimension then
                return { "system", "stellar", "galactic" }
            end

            return { "stellar", "system", "galactic" }
        end

        return { "galactic", "stellar", "system" }
    end

    return { "galactic", "stellar", "system" }
end

---@param book SgcAddressBook
---@param origin_site_id string
---@param destination_site_id string
---@return integer[]?
function resolver.get_best_address(book, origin_site_id, destination_site_id)
    if not visibility.can_see(book, origin_site_id, destination_site_id) then
        return nil
    end

    local origin = book.sites[origin_site_id]
    local destination = book.sites[destination_site_id]
    if origin == nil or destination == nil then
        return nil
    end

    for _, address_kind in ipairs(preferred_address_order(origin, destination)) do
        local address = destination.addresses[address_kind]
        if type(address) == "table" and #address > 0 then
            return address
        end
    end

    return nil
end

---@param book SgcAddressBook
---@param origin_site_id string
---@return SgcSiteEntry[]
function resolver.list_visible_destinations(book, origin_site_id)
    local destinations = {}

    if type(book) ~= "table" or type(book.sites) ~= "table" then
        return destinations
    end

    for destination_site_id, site in pairs(book.sites) do
        if visibility.can_see(book, origin_site_id, destination_site_id) then
            destinations[#destinations + 1] = site
        end
    end

    table.sort(destinations, function(left, right)
        if left.name == right.name then
            return left.id < right.id
        end
        return left.name < right.name
    end)

    return destinations
end

return resolver

