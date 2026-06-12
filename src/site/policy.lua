local address_book = require("address_book")

local policy = {}

---@param book SgcAddressBook
---@param site_id string
---@return boolean
function policy.allow_outbound(book, site_id)
    local site = book and book.sites and book.sites[site_id] or nil
    return type(site) == "table" and site.enabled == true and site.allow_outbound == true
end

---@param book SgcAddressBook
---@param origin_site_id string
---@param destination_site_id string
---@return boolean
function policy.can_dial(book, origin_site_id, destination_site_id)
    if not policy.allow_outbound(book, origin_site_id) then
        return false
    end

    if not address_book.can_see(book, origin_site_id, destination_site_id) then
        return false
    end

    return address_book.get_best_address(book, origin_site_id, destination_site_id) ~= nil
end

return policy

