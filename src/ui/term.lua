local widgets = require("ui.widgets")

local ui_term = {}

---@param title string
function ui_term.header(title)
    if term ~= nil and type(term.clear) == "function" then
        term.clear()
        term.setCursorPos(1, 1)
        local width = select(1, term.getSize())
        print(widgets.center_text(width, title))
        print(string.rep("=", math.min(width, #title)))
        return
    end

    print(title)
    print(string.rep("=", #title))
end

---@param values table<string, any>
function ui_term.key_values(values)
    for key, value in pairs(values) do
        print(string.format("%s: %s", key, tostring(value)))
    end
end

return ui_term

