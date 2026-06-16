local widgets = require("ui.widgets")

local ui_term = {}

---@class SgcTerminalCommandSpec
---@field summary string
---@field description string?

---@alias SgcTerminalPromptText string|string[]

---@class SgcTerminalPromptPage
---@field title string
---@field key string
---@field current_value string?
---@field default_value string?
---@field expected SgcTerminalPromptText?
---@field description SgcTerminalPromptText?
---@field error SgcTerminalPromptText?
---@field input_label string?

---@param width integer
---@param text string
---@return string
local function fit_line(width, text)
    local rendered = tostring(text or "")
    if width <= 0 then
        return ""
    end

    if #rendered <= width then
        return rendered
    end

    if width <= 3 then
        return rendered:sub(1, width)
    end

    return rendered:sub(1, width - 3) .. "..."
end

---@return integer
local function terminal_width()
    if term ~= nil and type(term.getSize) == "function" then
        local ok, width = pcall(term.getSize)
        if ok and type(width) == "number" and width > 0 then
            return width
        end
    end

    return 51
end

---@return integer
local function terminal_height()
    if term ~= nil and type(term.getSize) == "function" then
        local ok, _width, height = pcall(function()
            local width, resolved_height = term.getSize()
            return width, resolved_height
        end)
        if ok and type(height) == "number" and height > 0 then
            return height
        end
    end

    return 19
end

---@param commands (SgcTerminalCommandSpec|string)[]?
---@return SgcTerminalCommandSpec[]
local function ordered_command_specs(commands)
    local ordered = {}
    local seen = {}

    local function add_command(command)
        local summary = nil
        local description = nil
        if type(command) == "string" then
            summary = command
        elseif type(command) == "table" then
            summary = command.summary
            description = command.description
        end

        if type(summary) ~= "string" or summary == "" or seen[summary] == true then
            return
        end

        seen[summary] = true
        ordered[#ordered + 1] = {
            summary = summary,
            description = description,
        }
    end

    add_command({
        summary = "help",
        description = "Show available commands",
    })

    for _, command in ipairs(commands or {}) do
        add_command(command)
    end

    return ordered
end

---@param entries string[]
---@return string
local function join_entries(entries)
    if #entries == 0 then
        return ""
    end

    return table.concat(entries, " | ")
end

---@param label string
---@param width integer?
---@return string
function ui_term.format_title_line(label, width)
    local resolved_width = width or terminal_width()
    local title = fit_line(resolved_width, "=== " .. tostring(label or "") .. " ===")
    return widgets.center_text(resolved_width, title)
end

---@param commands (SgcTerminalCommandSpec|string)[]?
---@param width integer?
---@return string
function ui_term.format_commands_line(commands, width)
    local resolved_width = width or terminal_width()
    local prefix = ""
    local ordered = ordered_command_specs(commands)
    local visible_entries = {}

    for index, command in ipairs(ordered) do
        local candidate_entries = {}
        for candidate_index, entry in ipairs(visible_entries) do
            candidate_entries[candidate_index] = entry
        end
        candidate_entries[#candidate_entries + 1] = command.summary

        local hidden_count = #ordered - #candidate_entries
        local suffix = hidden_count > 0 and " | ..." or ""
        local candidate_line = prefix .. join_entries(candidate_entries) .. suffix
        if #candidate_line <= resolved_width then
            visible_entries = candidate_entries
        else
            break
        end
    end

    if #visible_entries == 0 then
        return fit_line(resolved_width, prefix .. ordered[1].summary)
    end

    local hidden_count = #ordered - #visible_entries
    local line = prefix .. join_entries(visible_entries)
    if hidden_count == 0 then
        return fit_line(resolved_width, line)
    end

    while #visible_entries > 0 and #(prefix .. join_entries(visible_entries) .. " | ...") > resolved_width do
        table.remove(visible_entries)
    end

    if #visible_entries == 0 then
        return fit_line(resolved_width, prefix .. ordered[1].summary)
    end

    return fit_line(resolved_width, prefix .. join_entries(visible_entries) .. " | ...")
end

---@param fallback_label string?
---@return string
function ui_term.current_computer_label(fallback_label)
    if type(os) == "table" and type(os.getComputerLabel) == "function" then
        local ok, label = pcall(os.getComputerLabel)
        if ok and type(label) == "string" and label ~= "" then
            return label
        end
    end

    return fallback_label or "computer"
end

---@param color integer?
local function set_text_color(color)
    if color == nil
        or term == nil
        or type(term.isColor) ~= "function"
        or type(term.setTextColor) ~= "function"
        or type(colors) ~= "table"
        or term.isColor() ~= true
    then
        return
    end

    pcall(term.setTextColor, color)
end

---@param row integer
---@param text string
---@param color integer?
local function write_terminal_row(row, text, color)
    if term == nil or type(term.setCursorPos) ~= "function" or type(term.write) ~= "function" then
        if color ~= nil then
            set_text_color(color)
        end
        print(text)
        if color ~= nil then
            set_text_color(colors ~= nil and colors.white or nil)
        end
        return
    end

    term.setCursorPos(1, row)
    if type(term.clearLine) == "function" then
        term.clearLine()
    end
    if color ~= nil then
        set_text_color(color)
    end
    term.write(text)
    if color ~= nil then
        set_text_color(colors ~= nil and colors.white or nil)
    end
end

local function wait_for_enter()
    if os ~= nil and type(os.pullEvent) == "function" and type(keys) == "table" then
        while true do
            local event, key = os.pullEvent("key")
            if event == "key" and key == keys.enter then
                return
            end
        end
    end

    if type(read) == "function" then
        read()
    end
end

local function clear_terminal()
    if term ~= nil and type(term.clear) == "function" then
        term.clear()
        if type(term.setCursorPos) == "function" then
            term.setCursorPos(1, 1)
        end
    end
end

---@param text SgcTerminalPromptText?
---@return string[]
local function normalize_text_lines(text)
    if type(text) == "table" then
        local lines = {}
        for _, line in ipairs(text) do
            lines[#lines + 1] = tostring(line)
        end
        return lines
    end

    if type(text) == "string" and text ~= "" then
        return { text }
    end

    return {}
end

---@param width integer
---@param text string
---@return string[]
local function wrap_line(width, text)
    local resolved_width = math.max(1, width)
    local line = tostring(text or "")
    if line == "" then
        return { "" }
    end

    local wrapped = {}
    local current = ""
    for word in line:gmatch("%S+") do
        local remaining = word
        while #remaining > resolved_width do
            if current ~= "" then
                wrapped[#wrapped + 1] = current
                current = ""
            end
            wrapped[#wrapped + 1] = remaining:sub(1, resolved_width)
            remaining = remaining:sub(resolved_width + 1)
        end

        if current == "" then
            current = remaining
        elseif #current + 1 + #remaining <= resolved_width then
            current = current .. " " .. remaining
        else
            wrapped[#wrapped + 1] = current
            current = remaining
        end
    end

    if current ~= "" then
        wrapped[#wrapped + 1] = current
    end

    return wrapped
end

---@param rows string[]
---@param width integer
---@param text SgcTerminalPromptText?
local function append_wrapped_rows(rows, width, text)
    for _, line in ipairs(normalize_text_lines(text)) do
        for _, wrapped in ipairs(wrap_line(width, line)) do
            rows[#rows + 1] = wrapped
        end
    end
end

---@param page SgcTerminalPromptPage
---@return string[]
local function prompt_value_rows(page)
    local rows = {
        "Key: " .. tostring(page.key or ""),
    }

    local has_current = type(page.current_value) == "string" and page.current_value ~= ""
    local has_default = type(page.default_value) == "string" and page.default_value ~= ""

    if has_current then
        rows[#rows + 1] = "Current: " .. page.current_value
    end

    if has_default and (not has_current or page.default_value ~= page.current_value) then
        rows[#rows + 1] = "Default: " .. page.default_value
    end

    return rows
end

---@param page SgcTerminalPromptPage
---@param width integer
---@return string[]
local function prompt_page_rows(page, width)
    local rows = {
        ui_term.format_title_line(page.title, width),
    }
    for _, row in ipairs(prompt_value_rows(page)) do
        rows[#rows + 1] = row
    end

    local expected = normalize_text_lines(page.expected)
    if #expected > 0 then
        rows[#rows + 1] = ""
        for _, line in ipairs(expected) do
            append_wrapped_rows(rows, width, "Expected: " .. line)
        end
    end

    local description = normalize_text_lines(page.description)
    if #description > 0 then
        rows[#rows + 1] = ""
        append_wrapped_rows(rows, width, description)
    end

    local errors = normalize_text_lines(page.error)
    if #errors > 0 then
        rows[#rows + 1] = ""
        for _, line in ipairs(errors) do
            append_wrapped_rows(rows, width, "Error: " .. line)
        end
    end

    return rows
end

---@param page SgcTerminalPromptPage
function ui_term.render_prompt_page(page)
    local width = terminal_width()
    local height = terminal_height()
    local rows = prompt_page_rows(page, width)
    local max_content_row = math.max(1, height - 2)
    local description_color = colors ~= nil and (colors.lightGray or colors.gray) or nil
    local error_color = colors ~= nil and colors.red or nil

    clear_terminal()

    if term == nil or type(term.setCursorPos) ~= "function" or type(term.write) ~= "function" then
        for _, text in ipairs(rows) do
            print(text)
        end
        return
    end

    for row = 1, max_content_row do
        local text = rows[row] or ""
        local color = nil
        if text:match("^Expected:") ~= nil then
            color = description_color
        elseif text:match("^Error:") ~= nil then
            color = error_color
        end
        write_terminal_row(row, fit_line(width, text), color)
    end
end

---@param page SgcTerminalPromptPage
---@return string?
function ui_term.read_prompt_page(page)
    ui_term.render_prompt_page(page)

    local width = terminal_width()
    local height = terminal_height()
    local input_label = type(page.input_label) == "string" and page.input_label or "> "
    if term ~= nil and type(term.setCursorPos) == "function" and type(term.write) == "function" then
        term.setCursorPos(1, height)
        if type(term.clearLine) == "function" then
            term.clearLine()
        end
        term.write(fit_line(width, input_label))
    elseif type(write) == "function" then
        write(input_label)
    else
        print(input_label)
    end

    if type(read) ~= "function" then
        return nil
    end

    return read()
end

---@param title string
function ui_term.header(title)
    if term ~= nil and type(term.clear) == "function" then
        clear_terminal()
        local width = select(1, term.getSize())
        print(widgets.center_text(width, title))
        print(string.rep("=", math.min(width, #title)))
        return
    end

    print(title)
    print(string.rep("=", #title))
end

---@param commands (SgcTerminalCommandSpec|string)[]?
---@param fallback_label string?
function ui_term.console_header(commands, fallback_label)
    local width = terminal_width()
    clear_terminal()

    print(ui_term.format_title_line(ui_term.current_computer_label(fallback_label), width))
    print(ui_term.format_commands_line(commands, width))
end

---@param commands (SgcTerminalCommandSpec|string)[]?
---@param fallback_label string?
function ui_term.show_help_screen(commands, fallback_label)
    local width = terminal_width()
    local height = terminal_height()
    local ordered = ordered_command_specs(commands)
    local description_color = colors ~= nil and (colors.lightGray or colors.gray) or nil
    local footer = "Press <Enter> to return"

    clear_terminal()

    write_terminal_row(1, ui_term.format_title_line(ui_term.current_computer_label(fallback_label), width))

    local row = 3
    local max_content_row = math.max(2, height - 2)
    for _, command in ipairs(ordered) do
        if row > max_content_row then
            break
        end

        write_terminal_row(row, fit_line(width, command.summary))
        row = row + 1

        if row > max_content_row then
            break
        end

        if type(command.description) == "string" and command.description ~= "" then
            write_terminal_row(row, fit_line(width, "  " .. command.description), description_color)
            row = row + 1
        end
    end

    write_terminal_row(height, fit_line(width, footer))
    wait_for_enter()
end

---@param commands (SgcTerminalCommandSpec|string)[]?
function ui_term.print_command_help(commands)
    print("Commands:")
    for _, command in ipairs(ordered_command_specs(commands)) do
        local line = "  " .. command.summary
        if type(command.description) == "string" and command.description ~= "" then
            line = line .. " - " .. command.description
        end
        print(line)
    end
end

---@param values table<string, any>
function ui_term.key_values(values)
    for key, value in pairs(values) do
        print(string.format("%s: %s", key, tostring(value)))
    end
end

return ui_term
