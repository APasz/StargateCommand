local resolver = require("peripheral.resolver")

local monitor = {}

---@class SgcMonitorRenderOptions
---@field text_scale number?
---@field clear boolean?

---@param candidate table?
---@return boolean
local function is_terminal_redirect(candidate)
    return type(candidate) == "table"
        and type(candidate.write) == "function"
        and type(candidate.setCursorPos) == "function"
        and type(candidate.getCursorPos) == "function"
end

---@param line string
---@param width integer?
---@return string
local function fit_line(line, width)
    local normalized = tostring(line or "")
    if type(width) ~= "number" or width <= 0 or #normalized <= width then
        return normalized
    end

    if width <= 1 then
        return normalized:sub(1, width)
    end

    return normalized:sub(1, width - 1) .. ">"
end

---@param side string
---@return SgcResult
local function resolve_monitor(side)
    return resolver.resolve(side, "monitor", is_terminal_redirect)
end

---@param terminal table
---@param foreground integer?
---@param background integer?
local function apply_colors(terminal, foreground, background)
    if type(terminal.setTextColor) == "function" and type(foreground) == "number" then
        terminal.setTextColor(foreground)
    end

    if type(terminal.setBackgroundColor) == "function" and type(background) == "number" then
        terminal.setBackgroundColor(background)
    end
end

---@param width integer?
---@param x integer
---@param wanted integer
---@return integer
local function clamp_width(width, x, wanted)
    if type(width) ~= "number" or width <= 0 then
        return wanted
    end

    if x > width then
        return 0
    end

    local available = width - x + 1
    if wanted > available then
        return available
    end

    return wanted
end

---@param terminal table
---@param x integer
---@param y integer
---@param text string
local function write_raw(terminal, x, y, text)
    terminal.setCursorPos(x, y)
    terminal.write(text)
end

---@param terminal table
---@param x integer
---@param y integer
---@param width integer
---@param background integer?
local function clear_span(terminal, x, y, width, background)
    if width <= 0 then
        return
    end

    apply_colors(terminal, nil, background)
    write_raw(terminal, x, y, string.rep(" ", width))
end

---@param terminal table
---@param width integer?
---@param height integer?
---@param id string
---@param remote boolean
---@return table
local function new_surface(terminal, width, height, id, remote)
    local surface = {
        terminal = terminal,
        width = width,
        height = height,
        id = id,
        remote = remote,
    }

    ---@param x integer
    ---@param y integer
    ---@param w integer
    ---@param h integer
    ---@param background integer?
    function surface:fill_rect(x, y, w, h, background)
        if w <= 0 or h <= 0 then
            return
        end

        for row = 0, h - 1 do
            local row_width = clamp_width(self.width, x, w)
            clear_span(self.terminal, x, y + row, row_width, background)
        end
    end

    ---@param x integer
    ---@param y integer
    ---@param w integer
    ---@param h integer
    ---@param background integer?
    function surface:frame_rect(x, y, w, h, background)
        if w <= 0 or h <= 0 then
            return
        end

        self:fill_rect(x, y, w, 1, background)
        if h > 1 then
            self:fill_rect(x, y + h - 1, w, 1, background)
        end
        if h > 2 then
            self:fill_rect(x, y + 1, 1, h - 2, background)
            if w > 1 then
                self:fill_rect(x + w - 1, y + 1, 1, h - 2, background)
            end
        end
    end

    ---@param x integer
    ---@param y integer
    ---@param text string
    ---@param options table?
    function surface:write_at(x, y, text, options)
        local normalized = tostring(text or "")
        local width_limit = type(options) == "table" and options.width or nil
        local align = type(options) == "table" and options.align or "left"
        local background = type(options) == "table" and options.background or nil
        local foreground = type(options) == "table" and options.foreground or nil
        local padded_width = nil

        if type(width_limit) == "number" and width_limit > 0 then
            padded_width = clamp_width(self.width, x, width_limit)
            if padded_width <= 0 then
                return
            end

            local visible = fit_line(normalized, padded_width)
            local start_x = x
            if align == "center" then
                start_x = x + math.floor((padded_width - #visible) / 2)
            elseif align == "right" then
                start_x = x + padded_width - #visible
            end

            clear_span(self.terminal, x, y, padded_width, background)
            apply_colors(self.terminal, foreground, background)
            write_raw(self.terminal, start_x, y, visible)
            return
        end

        local visible = fit_line(normalized, self.width ~= nil and self.width - x + 1 or nil)
        apply_colors(self.terminal, foreground, background)
        write_raw(self.terminal, x, y, visible)
    end

    ---@param y integer
    ---@param text string
    ---@param options table?
    function surface:write_line(y, text, options)
        self:write_at(1, y, text, {
            width = self.width,
            align = type(options) == "table" and options.align or "left",
            background = type(options) == "table" and options.background or nil,
            foreground = type(options) == "table" and options.foreground or nil,
        })
    end

    ---@param background integer?
    function surface:clear(background)
        if type(self.terminal.clear) == "function" then
            apply_colors(self.terminal, nil, background)
            self.terminal.clear()
        end
        if type(self.terminal.setCursorPos) == "function" then
            self.terminal.setCursorPos(1, 1)
        end
    end

    ---@param x integer
    ---@param y integer
    ---@param w integer
    ---@param h integer
    ---@param options table?
    function surface:draw_panel(x, y, w, h, options)
        local background = type(options) == "table" and options.background or nil
        local border = type(options) == "table" and options.border or nil

        self:fill_rect(x, y, w, h, background)
        if type(border) == "number" and w >= 2 and h >= 2 then
            self:frame_rect(x, y, w, h, border)
        end
    end

    return surface
end

---@param side string
---@param options SgcMonitorRenderOptions?
---@return SgcResult
function monitor.open(side, options)
    local resolved = resolve_monitor(side)
    if not resolved.ok then
        return resolved
    end

    local wrapped = resolved.value
    if type(options) == "table" and type(options.text_scale) == "number" and type(wrapped.setTextScale) == "function" then
        wrapped.setTextScale(options.text_scale)
    end

    local width = nil
    local height = nil
    if type(wrapped.getSize) == "function" then
        local monitor_width, monitor_height = wrapped.getSize()
        if type(monitor_width) == "number" then
            width = monitor_width
        end
        if type(monitor_height) == "number" then
            height = monitor_height
        end
    end

    local surface = new_surface(
        wrapped,
        width,
        height,
        resolved.details ~= nil and resolved.details.id or side,
        resolved.details ~= nil and resolved.details.remote == true or false
    )

    if options == nil or options.clear ~= false then
        surface:clear()
    end

    return {
        ok = true,
        value = surface,
    }
end

---@param side string
---@param lines string[]
---@param options SgcMonitorRenderOptions?
---@return SgcResult
function monitor.render(side, lines, options)
    local opened = monitor.open(side, options)
    if not opened.ok then
        return opened
    end

    local surface = opened.value
    for index, line in ipairs(lines) do
        surface:write_line(index, line)
    end

    return {
        ok = true,
        value = true,
    }
end

---@param line string
---@param width integer?
---@return string
function monitor.fit_line(line, width)
    return fit_line(line, width)
end

return monitor
