local class = {}

---@param name string
---@param prototype table?
---@return table
function class.define(name, prototype)
    local instance_methods = prototype or {}
    instance_methods.__index = instance_methods
    instance_methods.__name = name

    function instance_methods.new(...)
        local instance = setmetatable({}, instance_methods)
        if type(instance.init) == "function" then
            instance:init(...)
        end
        return instance
    end

    return instance_methods
end

return class

