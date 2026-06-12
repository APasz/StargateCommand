local tablex = {}

---@param source table
---@return table
function tablex.shallow_copy(source)
    local copy = {}
    for key, value in pairs(source) do
        copy[key] = value
    end
    return copy
end

---@param source any
---@return any
function tablex.deep_copy(source)
    if type(source) ~= "table" then
        return source
    end

    local copy = {}
    for key, value in pairs(source) do
        copy[tablex.deep_copy(key)] = tablex.deep_copy(value)
    end
    return copy
end

---@param target table
---@param overlay table?
---@return table
function tablex.deep_merge(target, overlay)
    if overlay == nil then
        return target
    end

    for key, value in pairs(overlay) do
        if type(value) == "table" and type(target[key]) == "table" then
            tablex.deep_merge(target[key], value)
        else
            target[key] = tablex.deep_copy(value)
        end
    end

    return target
end

---@param values any[]?
---@param wanted any
---@return boolean
function tablex.list_contains(values, wanted)
    if type(values) ~= "table" then
        return false
    end

    for _, value in ipairs(values) do
        if value == wanted then
            return true
        end
    end

    return false
end

return tablex

