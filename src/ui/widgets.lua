local widgets = {}

---@param width integer
---@param text string
---@return string
function widgets.center_text(width, text)
    if #text >= width then
        return text
    end

    local left_padding = math.floor((width - #text) / 2)
    return string.rep(" ", left_padding) .. text
end

return widgets

