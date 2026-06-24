local address_book = require("address_book")
local net_message = require("net.message")
local result = require("core.result")
local validate = require("core.validate")

local message = {}

---@param payload table
---@return SgcResult
function message.validate_get_book_request(payload)
    local errors = {}
    net_message.validate_routed_payload(payload, errors, "get_book", {
        site_controller = true,
        address_book = true,
    }, true)

    local validation = validate.result(errors)
    if not validation.ok then
        return validation
    end

    return result.ok(payload)
end

---@param payload table
---@return SgcResult
function message.validate_push_book_payload(payload)
    local errors = {}
    net_message.validate_snapshot_payload(payload, errors, "push_book", "book", address_book.validate)

    local validation = validate.result(errors)
    if not validation.ok then
        return validation
    end

    return result.ok(payload)
end

---@param payload table
---@return SgcResult
function message.validate_book_result(payload)
    local errors = {}
    net_message.validate_operation_result(payload, errors, "address_book_result", function(candidate, nested_errors)
        if candidate.book == nil or type(candidate.book) ~= "table" then
            validate.push_error(nested_errors, "payload.book", "expected address book snapshot")
            return
        end

        local validated_book = address_book.validate(candidate.book)
        if not validated_book.ok then
            local nested_validation_errors = validated_book.details ~= nil and validated_book.details.errors or {}
            for _, nested_error in ipairs(nested_validation_errors) do
                validate.push_error(nested_errors, "payload.book." .. nested_error.path, nested_error.message)
            end
        end
    end)

    local validation = validate.result(errors)
    if not validation.ok then
        return validation
    end

    return result.ok(payload)
end

---@param target_site string
---@param target_role SgcRole?
---@param request_id string?
---@return table
function message.build_get_book_request(target_site, target_role, request_id)
    return net_message.build_routed_payload("get_book", target_role or "address_book", target_site, {
        request_id = request_id,
    })
end

---@param request_id string
---@param operation SgcResult
---@return table
function message.build_book_result(request_id, operation)
    return net_message.build_operation_result("address_book_result", request_id, "book", operation)
end

---@param book SgcAddressBook
---@param sequence integer
---@param emitted_at integer
---@return table
function message.build_push_book_payload(book, sequence, emitted_at)
    return net_message.build_snapshot_payload("push_book", "book", book, sequence, emitted_at)
end

---@param payload table?
---@param target_role SgcRole
---@param target_site string
---@return boolean
function message.is_targeted_request(payload, target_role, target_site)
    return net_message.is_targeted_routed_payload(payload, target_role, target_site, "get_book")
end

return message
