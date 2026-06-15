local result = require("core.result")

local json = {}

local NULL = {}
local STRING_ESCAPES = {
    ['"'] = '\\"',
    ["\\"] = "\\\\",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
}

json.NULL = NULL

---@param value string
---@return string
local function encode_string(value)
    return '"' .. value:gsub('[%z\1-\31\\"]', function(character)
        local escaped = STRING_ESCAPES[character]
        if escaped ~= nil then
            return escaped
        end

        return string.format("\\u%04X", string.byte(character))
    end) .. '"'
end

---@param value table
---@return boolean, integer
local function is_array(value)
    local count = 0
    local max_index = 0

    for key in pairs(value) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
            return false, 0
        end

        count = count + 1
        if key > max_index then
            max_index = key
        end
    end

    return count == max_index, max_index
end

---@param value table
---@return string[]?
---@return SgcResult?
local function sorted_object_keys(value)
    local keys = {}

    for key in pairs(value) do
        if type(key) ~= "string" then
            return nil, result.err("json_encode_failed", {
                cause = "object keys must be strings",
                key = tostring(key),
            })
        end

        keys[#keys + 1] = key
    end

    table.sort(keys)
    return keys, nil
end

---@param value any
---@param depth integer
---@return string?
---@return SgcResult?
local function encode_value(value, depth)
    local value_type = type(value)

    if value == NULL or value_type == "nil" then
        return "null", nil
    end

    if value_type == "boolean" then
        return value and "true" or "false", nil
    end

    if value_type == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return nil, result.err("json_encode_failed", {
                cause = "numbers must be finite",
                value = value,
            })
        end

        return tostring(value), nil
    end

    if value_type == "string" then
        return encode_string(value), nil
    end

    if value_type ~= "table" then
        return nil, result.err("json_encode_failed", {
            cause = "unsupported value type",
            value_type = value_type,
        })
    end

    local array_like, length = is_array(value)
    local indentation = string.rep("  ", depth)
    local nested_indentation = string.rep("  ", depth + 1)

    if array_like then
        if length == 0 then
            return "[]", nil
        end

        local parts = { "[" }
        for index = 1, length do
            local encoded_item, encode_error = encode_value(value[index], depth + 1)
            if encoded_item == nil then
                return nil, encode_error
            end

            parts[#parts + 1] = "\n" .. nested_indentation .. encoded_item
            if index < length then
                parts[#parts] = parts[#parts] .. ","
            end
        end

        parts[#parts + 1] = "\n" .. indentation .. "]"
        return table.concat(parts), nil
    end

    local keys, key_error = sorted_object_keys(value)
    if keys == nil then
        return nil, key_error
    end

    if #keys == 0 then
        return "{}", nil
    end

    local parts = { "{" }
    for index, key in ipairs(keys) do
        local encoded_item, encode_error = encode_value(value[key], depth + 1)
        if encoded_item == nil then
            return nil, encode_error
        end

        parts[#parts + 1] = "\n" .. nested_indentation .. encode_string(key) .. ": " .. encoded_item
        if index < #keys then
            parts[#parts] = parts[#parts] .. ","
        end
    end

    parts[#parts + 1] = "\n" .. indentation .. "}"
    return table.concat(parts), nil
end

---@param payload string
---@param index integer
---@return integer
local function skip_whitespace(payload, index)
    while index <= #payload do
        local character = payload:sub(index, index)
        if character ~= " " and character ~= "\n" and character ~= "\r" and character ~= "\t" then
            break
        end

        index = index + 1
    end

    return index
end

---@param payload string
---@param index integer
---@param cause string
---@return SgcResult
local function decode_error(payload, index, cause)
    return result.err("json_decode_failed", {
        cause = cause,
        index = index,
        context = payload:sub(math.max(1, index - 20), math.min(#payload, index + 20)),
    })
end

---@param payload string
---@param index integer
---@return string?
---@return integer?
---@return SgcResult?
local function parse_string(payload, index)
    if payload:sub(index, index) ~= '"' then
        return nil, nil, decode_error(payload, index, 'expected \'"\'')
    end

    index = index + 1
    local parts = {}

    while index <= #payload do
        local character = payload:sub(index, index)
        if character == '"' then
            return table.concat(parts), index + 1, nil
        end

        if character == "\\" then
            local escaped = payload:sub(index + 1, index + 1)
            if escaped == '"' or escaped == "\\" or escaped == "/" then
                parts[#parts + 1] = escaped
                index = index + 2
            elseif escaped == "b" then
                parts[#parts + 1] = "\b"
                index = index + 2
            elseif escaped == "f" then
                parts[#parts + 1] = "\f"
                index = index + 2
            elseif escaped == "n" then
                parts[#parts + 1] = "\n"
                index = index + 2
            elseif escaped == "r" then
                parts[#parts + 1] = "\r"
                index = index + 2
            elseif escaped == "t" then
                parts[#parts + 1] = "\t"
                index = index + 2
            elseif escaped == "u" then
                local hex = payload:sub(index + 2, index + 5)
                if #hex ~= 4 or hex:match("^[0-9A-Fa-f]+$") == nil then
                    return nil, nil, decode_error(payload, index, "invalid unicode escape")
                end

                local codepoint = tonumber(hex, 16)
                if codepoint == nil then
                    return nil, nil, decode_error(payload, index, "invalid unicode escape")
                end

                if codepoint <= 255 then
                    parts[#parts + 1] = string.char(codepoint)
                elseif type(utf8) == "table" and type(utf8.char) == "function" then
                    local ok, unicode_character = pcall(utf8.char, codepoint)
                    if not ok then
                        return nil, nil, decode_error(payload, index, "unsupported unicode codepoint")
                    end
                    parts[#parts + 1] = unicode_character
                else
                    return nil, nil, decode_error(payload, index, "unicode escape requires utf8 support")
                end

                index = index + 6
            else
                return nil, nil, decode_error(payload, index, "invalid escape sequence")
            end
        else
            if string.byte(character) < 32 then
                return nil, nil, decode_error(payload, index, "control characters are not allowed in strings")
            end

            parts[#parts + 1] = character
            index = index + 1
        end
    end

    return nil, nil, decode_error(payload, index, "unterminated string")
end

---@param payload string
---@param index integer
---@return number?
---@return integer?
---@return SgcResult?
local function parse_number(payload, index)
    local number_text = payload:sub(index):match("^%-?%d+%.?%d*[eE]?[+-]?%d*")
    if number_text == nil or number_text == "" then
        return nil, nil, decode_error(payload, index, "invalid number")
    end

    local numeric = tonumber(number_text)
    if numeric == nil then
        return nil, nil, decode_error(payload, index, "invalid number")
    end

    return numeric, index + #number_text, nil
end

---@param payload string
---@param index integer
---@param expected string
---@param value any
---@return any?
---@return integer?
---@return SgcResult?
local function parse_literal(payload, index, expected, value)
    if payload:sub(index, index + #expected - 1) ~= expected then
        return nil, nil, decode_error(payload, index, "expected " .. expected)
    end

    return value, index + #expected, nil
end

---@param payload string
---@param index integer
---@return any?
---@return integer?
---@return SgcResult?
local function parse_value(payload, index)
    index = skip_whitespace(payload, index)
    local character = payload:sub(index, index)

    if character == "{" then
        local value = {}
        index = index + 1
        index = skip_whitespace(payload, index)

        if payload:sub(index, index) == "}" then
            return value, index + 1, nil
        end

        while true do
            local key, next_index, key_error = parse_string(payload, index)
            if key == nil then
                return nil, nil, key_error
            end

            index = skip_whitespace(payload, next_index)
            if payload:sub(index, index) ~= ":" then
                return nil, nil, decode_error(payload, index, "expected ':'")
            end

            local parsed_value, value_index, value_error = parse_value(payload, index + 1)
            if value_error ~= nil then
                return nil, nil, value_error
            end

            value[key] = parsed_value == NULL and nil or parsed_value
            index = skip_whitespace(payload, value_index)
            local terminator = payload:sub(index, index)
            if terminator == "}" then
                return value, index + 1, nil
            end

            if terminator ~= "," then
                return nil, nil, decode_error(payload, index, "expected ',' or '}'")
            end

            index = skip_whitespace(payload, index + 1)
        end
    end

    if character == "[" then
        local value = {}
        index = index + 1
        index = skip_whitespace(payload, index)

        if payload:sub(index, index) == "]" then
            return value, index + 1, nil
        end

        local array_index = 1
        while true do
            local parsed_value, value_index, value_error = parse_value(payload, index)
            if value_error ~= nil then
                return nil, nil, value_error
            end

            if parsed_value == NULL then
                return nil, nil, decode_error(payload, index, "null array entries are unsupported")
            end

            value[array_index] = parsed_value
            array_index = array_index + 1

            index = skip_whitespace(payload, value_index)
            local terminator = payload:sub(index, index)
            if terminator == "]" then
                return value, index + 1, nil
            end

            if terminator ~= "," then
                return nil, nil, decode_error(payload, index, "expected ',' or ']'")
            end

            index = skip_whitespace(payload, index + 1)
        end
    end

    if character == '"' then
        return parse_string(payload, index)
    end

    if character == "-" or character:match("%d") ~= nil then
        return parse_number(payload, index)
    end

    if character == "t" then
        return parse_literal(payload, index, "true", true)
    end

    if character == "f" then
        return parse_literal(payload, index, "false", false)
    end

    if character == "n" then
        return parse_literal(payload, index, "null", NULL)
    end

    return nil, nil, decode_error(payload, index, "unexpected character")
end

---@param value any
---@return SgcResult
function json.encode(value)
    local encoded, encode_error = encode_value(value, 0)
    if encoded == nil then
        return encode_error
    end

    return result.ok(encoded)
end

---@param payload string
---@return SgcResult
function json.decode(payload)
    if type(payload) ~= "string" then
        return result.err("json_decode_failed", {
            cause = "expected string payload",
        })
    end

    local decoded, next_index, decode_result = parse_value(payload, 1)
    if decode_result ~= nil then
        return decode_result
    end

    local trailing_index = skip_whitespace(payload, next_index)
    if trailing_index <= #payload then
        return decode_error(payload, trailing_index, "unexpected trailing content")
    end

    return result.ok(decoded == NULL and nil or decoded)
end

return json
