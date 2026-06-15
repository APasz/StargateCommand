local address_book = require("address_book")
local command_schema = require("command.schema")
local policy = require("site.policy")
local result = require("core.result")

local command = {}

---@param book SgcAddressBook
---@param origin_site_id string
---@param request_payload table
---@return SgcResult
function command.plan(book, origin_site_id, request_payload)
    local validated = command_schema.validate_site_command_request(request_payload)
    if not validated.ok then
        return validated
    end

    local request = validated.value
    if request.action ~= "dial" then
        return result.ok({
            action = request.action,
            request_id = request.request_id,
        })
    end

    if type(book) ~= "table" or type(book.sites) ~= "table" then
        return result.err("address_book_unavailable", {
            origin_site = origin_site_id,
            destination_site = request.destination_site,
        })
    end

    local origin_site = book.sites[origin_site_id]
    local destination_site = book.sites[request.destination_site]
    if type(origin_site) ~= "table" then
        return result.err("unknown_origin_site", {
            origin_site = origin_site_id,
        })
    end

    if type(destination_site) ~= "table" then
        return result.err("unknown_destination_site", {
            origin_site = origin_site_id,
            destination_site = request.destination_site,
        })
    end

    if not policy.can_dial(book, origin_site_id, request.destination_site) then
        return result.err("dial_not_allowed", {
            origin_site = origin_site_id,
            destination_site = request.destination_site,
        })
    end

    local resolved_address = address_book.get_best_address(book, origin_site_id, request.destination_site)
    if resolved_address == nil then
        return result.err("dial_address_unavailable", {
            origin_site = origin_site_id,
            destination_site = request.destination_site,
        })
    end

    return result.ok({
        action = request.action,
        request_id = request.request_id,
        destination_site = request.destination_site,
        address = resolved_address,
        dial_mode = request.dial_mode or nil,
    })
end

return command
