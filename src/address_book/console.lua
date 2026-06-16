local debug_dump = require("address_book.debug_dump")
local editor = require("address_book.editor")
local store = require("address_book.store")
local constants = require("core.constants")
local tablex = require("core.tablex")
local ui_term = require("ui.term")
local validate = require("core.validate")
local address_book_message = require("address_book.message")
local address_book_network = require("address_book.network")
local time = require("core.time")

local console = {}

local CLEAR_VALUE_TOKEN = "-"
local ADDRESS_BOOK_UPDATE_TITLE = "Address Book Update"

---@param path string
---@return string
local function basename(path)
    local normalized = tostring(path):gsub("\\", "/")
    return normalized:match("([^/]+)$") or normalized
end

---@param path string
---@return string
local function file_stem(path)
    return basename(path):match("^(.*)%.") or basename(path)
end

---@return string
local function default_updated_by()
    return ui_term.current_computer_label(file_stem(constants.DEFAULT_ADDRESS_BOOK_SERVER_PATH))
end

---@param message string
local function print_error(message)
    if type(printError) == "function" then
        printError("[sgc] " .. message)
        return
    end

    print("[sgc] " .. message)
end

---@param value boolean
---@return string
local function format_boolean(value)
    return value and "yes" or "no"
end

---@param title string
---@param key string
---@param current_value string?
---@param default_value string?
---@param expected SgcTerminalPromptText?
---@param description SgcTerminalPromptText?
---@param error_message string?
---@return string
local function read_prompt_value(title, key, current_value, default_value, expected, description, error_message)
    local answer = ui_term.read_prompt_page({
        title = title,
        key = key,
        current_value = current_value,
        default_value = default_value,
        expected = expected,
        description = description,
        error = error_message,
        input_label = "> ",
    })
    if answer == nil then
        error("terminal input is unavailable")
    end

    return answer
end

---@param lines string[]
---@param text SgcTerminalPromptText?
local function append_prompt_text(lines, text)
    if type(text) == "table" then
        for _, line in ipairs(text) do
            lines[#lines + 1] = line
        end
    elseif type(text) == "string" and text ~= "" then
        lines[#lines + 1] = text
    end
end

---@param current_value string?
---@param default_value string?
---@param help_text SgcTerminalPromptText?
---@return string[]
local function required_text_description(current_value, default_value, help_text)
    local description = {}
    append_prompt_text(description, help_text)

    if current_value ~= nil and current_value ~= "" then
        description[#description + 1] = "Press Enter to keep the current value."
        return description
    end

    if default_value ~= nil and default_value ~= "" then
        description[#description + 1] = "Press Enter to use the default value."
        return description
    end

    description[#description + 1] = "Enter a value for this field."
    return description
end

---@param title string
---@param key string
---@param current_value string?
---@param default_value string?
---@param help_text SgcTerminalPromptText?
---@return string
local function read_line(title, key, current_value, default_value, help_text)
    local error_message = nil
    while true do
        local answer = read_prompt_value(
            title,
            key,
            current_value,
            default_value,
            "non-empty text",
            required_text_description(current_value, default_value, help_text),
            error_message
        )
        if answer == "" and current_value ~= nil and current_value ~= "" then
            return current_value
        end

        if answer == "" and default_value ~= nil and default_value ~= "" then
            return default_value
        end

        if answer ~= "" then
            return answer
        end

        error_message = "Please enter a value."
    end
end

---@param title string
---@param key string
---@param current_value string?
---@param allow_clear boolean
---@param expected SgcTerminalPromptText?
---@param description SgcTerminalPromptText?
---@return string?
local function read_optional_line(title, key, current_value, allow_clear, expected, description)
    local resolved_description = {}
    append_prompt_text(resolved_description, description)

    if current_value ~= nil and current_value ~= "" then
        resolved_description[#resolved_description + 1] = "Leave blank to keep the current value."
    else
        resolved_description[#resolved_description + 1] = "Leave blank to omit this field."
    end

    if allow_clear then
        resolved_description[#resolved_description + 1] = "Enter " .. CLEAR_VALUE_TOKEN .. " to clear the current value."
    end

    local answer = read_prompt_value(title, key, current_value, nil, expected, resolved_description, nil)
    if answer == "" then
        return current_value
    end

    if allow_clear and answer == CLEAR_VALUE_TOKEN then
        return nil
    end

    return answer
end

---@param title string
---@param key string
---@param current_value boolean?
---@param default_value boolean
---@param help_text SgcTerminalPromptText?
---@return boolean
local function read_yes_no(title, key, current_value, default_value, help_text)
    local current_text = current_value ~= nil and format_boolean(current_value) or nil
    local default_text = current_value == nil and format_boolean(default_value) or nil
    local fallback = current_value
    if fallback == nil then
        fallback = default_value
    end
    local error_message = nil
    while true do
        local description = {}
        append_prompt_text(description, help_text)
        description[#description + 1] = "Accepted values: y, yes, n, no."
        description[#description + 1] = "Press Enter to use the shown value."

        local answer = string.lower(read_prompt_value(title, key, current_text, default_text, "yes or no", description, error_message))
        if answer == "" then
            return fallback
        end

        if answer == "y" or answer == "yes" then
            return true
        end

        if answer == "n" or answer == "no" then
            return false
        end

        error_message = "Please answer yes or no."
    end
end

---@param raw_value string?
---@return string[]?
local function parse_csv_strings(raw_value)
    if raw_value == nil or raw_value == "" then
        return nil
    end

    local values = {}
    for chunk in raw_value:gmatch("[^,]+") do
        local trimmed = chunk:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            values[#values + 1] = trimmed
        end
    end

    if #values == 0 then
        return nil
    end

    return values
end

---@param values string[]?
---@return string?
local function join_csv_strings(values)
    if type(values) ~= "table" or #values == 0 then
        return nil
    end

    return table.concat(values, ",")
end

---@param values integer[]?
---@return string?
local function join_address(values)
    if type(values) ~= "table" or #values == 0 then
        return nil
    end

    local parts = {}
    for index, value in ipairs(values) do
        parts[index] = tostring(value)
    end

    return table.concat(parts, ",")
end

---@param title string
---@param key string
---@param expected_length integer
---@param current_value integer[]?
---@param allow_clear boolean
---@param help_text SgcTerminalPromptText?
---@return integer[]?
local function read_address(title, key, expected_length, current_value, allow_clear, help_text)
    local current_text = join_address(current_value)
    local error_message = nil
    while true do
        local description = {}
        append_prompt_text(description, help_text)
        description[#description + 1] = current_text ~= nil and "Press Enter to keep the current address."
            or "Leave blank to omit this address."
        if allow_clear then
            description[#description + 1] = "Enter " .. CLEAR_VALUE_TOKEN .. " to clear the current address."
        end

        local value = read_prompt_value(title, key, current_text, nil, {
            "comma-separated whole numbers",
            "exactly " .. tostring(expected_length) .. " symbols",
            "each symbol must be >= 0",
        }, description, error_message)
        if value == "" and current_value ~= nil then
            return tablex.deep_copy(current_value)
        end

        if allow_clear and value == CLEAR_VALUE_TOKEN then
            return nil
        end

        if value == "" then
            return nil
        end

        local parsed = {}
        local valid = true
        for chunk in value:gmatch("[^,]+") do
            local trimmed = chunk:match("^%s*(.-)%s*$")
            local numeric = tonumber(trimmed)
            if numeric == nil or numeric % 1 ~= 0 or numeric < 0 then
                valid = false
                break
            end

            parsed[#parsed + 1] = numeric
        end

        if valid and #parsed == expected_length then
            return parsed
        end

        error_message = "Please enter exactly " .. tostring(expected_length) .. " whole numbers >= 0."
    end
end

---@param title string
---@param key string
---@param current_value string[]?
---@param allow_clear boolean
---@param help_text SgcTerminalPromptText?
---@return string[]?
local function read_csv_field(title, key, current_value, allow_clear, help_text)
    local current_csv = join_csv_strings(current_value)
    local description = {}
    append_prompt_text(description, help_text)
    description[#description + 1] = "Whitespace around commas is ignored."

    local value = read_optional_line(title, key, current_csv, allow_clear, {
        "comma-separated values",
        "each value must be a site id or *",
    }, description)
    if value == current_csv and current_value ~= nil then
        return tablex.deep_copy(current_value)
    end

    return parse_csv_strings(value)
end

---@param site_id string
---@param existing_site SgcSiteEntry?
---@return SgcSiteEntry
local function prompt_for_site(site_id, existing_site)
    local is_edit = existing_site ~= nil
    local title = (is_edit and "Edit Site: " or "Add Site: ") .. site_id

    local site = {
        enabled = read_yes_no(
            title,
            "Enabled",
            is_edit and existing_site.enabled or nil,
            true,
            "Disabled sites stay in the address book but are ignored by destination lists and outbound dialing."
        ),
        allow_outbound = read_yes_no(
            title,
            "Allow outbound dialing",
            is_edit and existing_site.allow_outbound or nil,
            true,
            "Controls whether consoles may dial this site as a destination."
        ),
        id = site_id,
        name = read_line(
            title,
            "Display name",
            is_edit and existing_site.name or nil,
            nil,
            "Human-readable name shown in destination lists and operator output."
        ),
        location = {
            universe = read_line(
                title,
                "Universe",
                is_edit and existing_site.location.universe or nil,
                "minecraft",
                "Broadest location grouping for the site, usually the Minecraft world or server namespace."
            ),
            galaxy = read_line(
                title,
                "Galaxy",
                is_edit and existing_site.location.galaxy or nil,
                "milkyway",
                "Galaxy name used to group addresses and decide which address tier is appropriate."
            ),
            dimension = read_line(
                title,
                "Dimension",
                is_edit and existing_site.location.dimension or nil,
                "overworld",
                "Dimension or local region name where the gate is installed."
            ),
        },
        addresses = {
            system = read_address(
                title,
                "System address",
                constants.ADDRESS_LENGTHS.system,
                existing_site ~= nil and existing_site.addresses.system or nil,
                is_edit,
                "Shortest address for gates in the same local system."
            ),
            stellar = read_address(
                title,
                "Stellar address",
                constants.ADDRESS_LENGTHS.stellar,
                existing_site ~= nil and existing_site.addresses.stellar or nil,
                is_edit,
                "Address used for gates in the same galaxy when a system address is not enough."
            ),
            galactic = read_address(
                title,
                "Galactic address",
                constants.ADDRESS_LENGTHS.galactic,
                existing_site ~= nil and existing_site.addresses.galactic or nil,
                is_edit,
                "Longest address tier for remote or cross-galaxy destinations."
            ),
        },
        visibility = {
            listed = read_yes_no(
                title,
                "Listed in destination lists",
                is_edit and existing_site.visibility.listed or nil,
                true,
                "When no, the site remains valid but is omitted from normal destination lists."
            ),
            hidden_at = read_csv_field(
                title,
                "Hidden at site ids or *",
                existing_site ~= nil and existing_site.visibility.hidden_at or nil,
                is_edit,
                "Source sites listed here cannot see this destination. Use * to hide it everywhere."
            ),
            visible_from = read_csv_field(
                title,
                "Visible only from site ids or *",
                existing_site ~= nil and existing_site.visibility.visible_from or nil,
                is_edit,
                "If set, only these source sites can see this destination. Leave blank for no allowlist."
            ),
            intergalactic = read_csv_field(
                title,
                "Intergalactic visibility site ids or *",
                existing_site ~= nil and existing_site.visibility.intergalactic or nil,
                is_edit,
                "Sites listed here may see this destination even when it is outside their normal galaxy scope."
            ),
        },
        tags = read_csv_field(
            title,
            "Tags",
            existing_site ~= nil and existing_site.tags or nil,
            is_edit,
            "Optional labels for grouping or future filtering. Tags do not change dialing behavior today."
        ),
        notes = read_optional_line(
            title,
            "Notes",
            existing_site ~= nil and existing_site.notes or nil,
            is_edit,
            "free text",
            {
                "Optional operator notes for this site. Notes do not affect visibility or dialing behavior.",
            }
        ),
    }

    return site
end

---@param config table
---@param runtime table
---@param logger table
---@param updated_book SgcAddressBook
---@param updated_by string
---@param action string
---@param site_id string
---@return boolean
local function persist_book(config, runtime, logger, updated_book, updated_by, action, site_id)
    local saved = store.save(runtime.path, updated_book)
    if not saved.ok then
        print_error("failed to save address book")
        return false
    end

    runtime.book = updated_book
    debug_dump.save_snapshot(config, {
        status = "available",
        source = "server_file",
        path = runtime.path,
        book = updated_book,
    })
    logger:info("address book updated", {
        action = action,
        site_id = site_id,
        revision = updated_book.revision,
        updated_by = updated_by,
    })
    return true
end

---@param config table
---@param runtime table
---@param logger table
local function push_book(config, runtime, logger)
    local payload = address_book_message.build_push_book_payload(runtime.book, runtime.book.revision, time.now_ms())
    local pushed = address_book_network.broadcast_payload(config, payload)
    if not pushed.ok then
        print_error("push failed: " .. tostring(pushed.error))
        return
    end

    logger:info("address book push broadcast", {
        revision = runtime.book.revision,
    })
    print("Pushed revision " .. tostring(runtime.book.revision))
end

---@param mutation_result SgcResult
local function print_validation_errors(mutation_result)
    local errors = mutation_result.details ~= nil and mutation_result.details.errors or nil
    if type(errors) ~= "table" or #errors == 0 then
        return
    end

    print("Validation errors:")
    for _, failure in ipairs(errors) do
        local path = type(failure.path) == "string" and failure.path or "unknown"
        local message = type(failure.message) == "string" and failure.message or "validation failed"
        print(string.format(" - %s: %s", path, message))
    end
end

---@param runtime table
---@return string[]
local function sorted_site_ids(runtime)
    local site_ids = {}
    for site_id in pairs(runtime.book.sites) do
        site_ids[#site_ids + 1] = site_id
    end

    table.sort(site_ids)
    return site_ids
end

---@param config table
---@param runtime table
---@param logger table
local function list_sites(_config, runtime, _logger)
    local site_ids = sorted_site_ids(runtime)
    if #site_ids == 0 then
        print("No sites in address book.")
        return
    end

    print(string.format("Revision %d | Updated by %s", runtime.book.revision, runtime.book.updated_by))
    for _, site_id in ipairs(site_ids) do
        local site = runtime.book.sites[site_id]
        local status = site.enabled and "enabled" or "disabled"
        print(string.format("%s | %s | %s | %s/%s/%s", site_id, site.name, status, site.location.universe, site.location.galaxy, site.location.dimension))
    end
end

---@param config table
---@param runtime table
---@param logger table
---@param site_id string?
local function add_site(config, runtime, logger, site_id)
    if not validate.is_site_id(site_id) then
        print_error("usage: add <site_id>")
        return
    end

    if runtime.book.sites[site_id] ~= nil then
        print_error("site already exists: " .. site_id)
        return
    end

    local updated_by = read_line(
        ADDRESS_BOOK_UPDATE_TITLE,
        "Updated by",
        nil,
        default_updated_by(),
        "Operator or computer name recorded on the address-book revision."
    )
    local site = prompt_for_site(site_id, nil)
    local updated_book = editor.add_site(runtime.book, site, updated_by)
    if not updated_book.ok then
        print_error("new site failed validation")
        print_validation_errors(updated_book)
        return
    end

    if not read_yes_no(
        ADDRESS_BOOK_UPDATE_TITLE,
        "Save changes",
        nil,
        true,
        "Writes the new site to the authoritative address-book file."
    ) then
        print("Cancelled.")
        return
    end

    if persist_book(config, runtime, logger, updated_book.value, updated_by, "add", site_id) then
        print("Saved " .. site_id)
    end
end

---@param config table
---@param runtime table
---@param logger table
---@param site_id string?
local function edit_site(config, runtime, logger, site_id)
    if not validate.is_site_id(site_id) then
        print_error("usage: edit <site_id>")
        return
    end

    local existing_site = runtime.book.sites[site_id]
    if existing_site == nil then
        print_error("unknown site: " .. site_id)
        return
    end

    local updated_by = read_line(
        ADDRESS_BOOK_UPDATE_TITLE,
        "Updated by",
        nil,
        default_updated_by(),
        "Operator or computer name recorded on the address-book revision."
    )
    local site = prompt_for_site(site_id, existing_site)
    local updated_book = editor.update_site(runtime.book, site, updated_by)
    if not updated_book.ok then
        print_error("updated site failed validation")
        print_validation_errors(updated_book)
        return
    end

    if not read_yes_no(
        ADDRESS_BOOK_UPDATE_TITLE,
        "Save changes",
        nil,
        true,
        "Writes the edited site to the authoritative address-book file."
    ) then
        print("Cancelled.")
        return
    end

    if persist_book(config, runtime, logger, updated_book.value, updated_by, "edit", site_id) then
        print("Updated " .. site_id)
    end
end

---@param config table
---@param runtime table
---@param logger table
---@param site_id string?
local function delete_site(config, runtime, logger, site_id)
    if not validate.is_site_id(site_id) then
        print_error("usage: del <site_id>")
        return
    end

    local existing_site = runtime.book.sites[site_id]
    if existing_site == nil then
        print_error("unknown site: " .. site_id)
        return
    end

    local title = "Delete Site: " .. site_id
    if not read_yes_no(
        title,
        "Confirm delete " .. existing_site.name,
        nil,
        false,
        "Deletes this site from the authoritative address book. This cannot be undone from the console."
    ) then
        print("Cancelled.")
        return
    end

    local updated_by = read_line(
        title,
        "Updated by",
        nil,
        default_updated_by(),
        "Operator or computer name recorded on the address-book revision."
    )
    local updated_book = editor.remove_site(runtime.book, site_id, updated_by)
    if not updated_book.ok then
        print_error("delete failed")
        return
    end

    if persist_book(config, runtime, logger, updated_book.value, updated_by, "delete", site_id) then
        print("Deleted " .. site_id)
    end
end

local COMMAND_HANDLERS = {
    list = list_sites,
    add = add_site,
    edit = edit_site,
    del = delete_site,
    push = push_book,
}

local COMMAND_SPECS = {
    {
        summary = "help",
        description = "Show available commands",
    },
    {
        summary = "list",
        description = "List sites in the address book",
    },
    {
        summary = "add <site_id>",
        description = "Create a new site entry",
    },
    {
        summary = "edit <site_id>",
        description = "Edit an existing site entry",
    },
    {
        summary = "del <site_id>",
        description = "Delete an existing site entry",
    },
    {
        summary = "push",
        description = "Broadcast the latest address book revision",
    },
}

local function print_help()
    ui_term.show_help_screen(COMMAND_SPECS, file_stem(constants.DEFAULT_ADDRESS_BOOK_SERVER_PATH))
end

local function print_console_home()
    ui_term.console_header(COMMAND_SPECS, file_stem(constants.DEFAULT_ADDRESS_BOOK_SERVER_PATH))
    print("Address book console ready.")
end

---@param line string
---@return string[]
local function tokenize(line)
    local parts = {}
    for part in tostring(line):gmatch("%S+") do
        parts[#parts + 1] = part
    end

    return parts
end

---@param config table
---@param runtime table
---@param logger table
function console.run(config, runtime, logger)
    print_console_home()

    while true do
        write("address-book> ")
        local line = read()
        local parts = tokenize(line)
        local command = parts[1]
        if command == nil then
        elseif command == "help" then
            print_help()
            print_console_home()
        else
            local handler = COMMAND_HANDLERS[command]
            if handler == nil then
                print_error("unknown command: " .. tostring(command))
            else
                handler(config, runtime, logger, parts[2])
            end
        end
    end
end

return console
