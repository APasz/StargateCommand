local debug_dump = require("address_book.debug_dump")
local editor = require("address_book.editor")
local store = require("address_book.store")
local constants = require("core.constants")
local tablex = require("core.tablex")
local validate = require("core.validate")
local address_book_message = require("address_book.message")
local address_book_network = require("address_book.network")
local time = require("core.time")

local console = {}

local CLEAR_VALUE_TOKEN = "-"

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
    if type(os) == "table" and type(os.getComputerLabel) == "function" then
        local ok, label = pcall(os.getComputerLabel)
        if ok and type(label) == "string" and label ~= "" then
            return label
        end
    end

    if type(computer) == "table" and type(computer.getLabel) == "function" then
        local ok, label = pcall(computer.getLabel)
        if ok and type(label) == "string" and label ~= "" then
            return label
        end
    end

    return file_stem(constants.DEFAULT_ADDRESS_BOOK_SERVER_PATH)
end

---@param message string
local function print_error(message)
    if type(printError) == "function" then
        printError("[sgc] " .. message)
        return
    end

    print("[sgc] " .. message)
end

---@param prompt string
---@param suffix string?
local function begin_prompt(prompt, suffix)
    if suffix ~= nil and suffix ~= "" then
        print(prompt .. suffix)
    else
        print(prompt)
    end

    write("> ")
end

---@param prompt string
---@param default_value string?
---@return string
local function read_line(prompt, default_value)
    while true do
        if default_value ~= nil and default_value ~= "" then
            begin_prompt(prompt, " [" .. default_value .. "]")
        else
            begin_prompt(prompt, nil)
        end

        local answer = read()
        if answer == "" and default_value ~= nil and default_value ~= "" then
            return default_value
        end

        if answer ~= "" then
            return answer
        end

        print("Please enter a value.")
    end
end

---@param prompt string
---@param current_value string?
---@param allow_clear boolean
---@return string?
local function read_optional_line(prompt, current_value, allow_clear)
    local suffix = current_value ~= nil and current_value ~= "" and " [" .. current_value .. "]" or " (optional)"
    if allow_clear then
        suffix = suffix .. " (blank keeps; `-` clears)"
    end

    begin_prompt(prompt, suffix)
    local answer = read()
    if answer == "" then
        return current_value
    end

    if allow_clear and answer == CLEAR_VALUE_TOKEN then
        return nil
    end

    return answer
end

---@param prompt string
---@param default_value boolean
---@return boolean
local function read_yes_no(prompt, default_value)
    local suffix = default_value and " [Y/n]: " or " [y/N]: "

    while true do
        begin_prompt(prompt, suffix:sub(1, -3))
        local answer = string.lower(read())
        if answer == "" then
            return default_value
        end

        if answer == "y" or answer == "yes" then
            return true
        end

        if answer == "n" or answer == "no" then
            return false
        end

        print("Please answer yes or no.")
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

---@param prompt string
---@param expected_length integer
---@param current_value integer[]?
---@param allow_clear boolean
---@return integer[]?
local function read_address(prompt, expected_length, current_value, allow_clear)
    local default_value = join_address(current_value)
    while true do
        local value = read_optional_line(prompt .. " (" .. tostring(expected_length) .. " symbols)", default_value, allow_clear)
        if value == default_value and current_value ~= nil then
            return tablex.deep_copy(current_value)
        end

        if value == nil or value == "" then
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

        print("Please enter exactly " .. tostring(expected_length) .. " whole numbers >= 0.")
    end
end

---@param prompt string
---@param current_value string[]?
---@param allow_clear boolean
---@return string[]?
local function read_csv_field(prompt, current_value, allow_clear)
    local current_csv = join_csv_strings(current_value)
    local value = read_optional_line(prompt .. " (comma-separated)", current_csv, allow_clear)
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
    if is_edit then
        print("Editing " .. site_id .. ". Blank keeps; `-` clears")
    else
        print("Adding " .. site_id .. ".")
    end

    local site = {
        enabled = read_yes_no("Enabled", existing_site == nil or existing_site.enabled),
        allow_outbound = read_yes_no("Allow outbound dialing", existing_site == nil or existing_site.allow_outbound),
        id = site_id,
        name = is_edit and read_line("Display name", existing_site.name) or read_line("Display name", nil),
        location = {
            universe = is_edit and read_line("Universe", existing_site.location.universe) or read_line("Universe", "minecraft"),
            galaxy = is_edit and read_line("Galaxy", existing_site.location.galaxy) or read_line("Galaxy", "milkyway"),
            dimension = is_edit and read_line("Dimension", existing_site.location.dimension) or read_line("Dimension", "overworld"),
        },
        addresses = {
            system = read_address("System address", constants.ADDRESS_LENGTHS.system, existing_site ~= nil and existing_site.addresses.system or nil, is_edit),
            stellar = read_address(
                "Stellar address",
                constants.ADDRESS_LENGTHS.stellar,
                existing_site ~= nil and existing_site.addresses.stellar or nil,
                is_edit
            ),
            galactic = read_address(
                "Galactic address",
                constants.ADDRESS_LENGTHS.galactic,
                existing_site ~= nil and existing_site.addresses.galactic or nil,
                is_edit
            ),
        },
        visibility = {
            listed = read_yes_no("Listed in destination lists", existing_site == nil or existing_site.visibility.listed),
            hidden_at = read_csv_field("Hidden at site ids or *", existing_site ~= nil and existing_site.visibility.hidden_at or nil, is_edit),
            visible_from = read_csv_field("Visible only from site ids or *", existing_site ~= nil and existing_site.visibility.visible_from or nil, is_edit),
            intergalactic = read_csv_field(
                "Intergalactic visibility site ids or *",
                existing_site ~= nil and existing_site.visibility.intergalactic or nil,
                is_edit
            ),
        },
        tags = read_csv_field("Tags", existing_site ~= nil and existing_site.tags or nil, is_edit),
        notes = read_optional_line("Notes", existing_site ~= nil and existing_site.notes or nil, is_edit),
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
    local payload =
        address_book_message.build_push_book_payload(runtime.book, runtime.book.revision, time.now_ms())
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

    local updated_by = read_line("Updated by", default_updated_by())
    local site = prompt_for_site(site_id, nil)
    local updated_book = editor.add_site(runtime.book, site, updated_by)
    if not updated_book.ok then
        print_error("new site failed validation")
        print_validation_errors(updated_book)
        return
    end

    if not read_yes_no("Save changes", true) then
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

    local updated_by = read_line("Updated by", default_updated_by())
    local site = prompt_for_site(site_id, existing_site)
    local updated_book = editor.update_site(runtime.book, site, updated_by)
    if not updated_book.ok then
        print_error("updated site failed validation")
        print_validation_errors(updated_book)
        return
    end

    if not read_yes_no("Save changes", true) then
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

    print(string.format("Delete %s (%s)", site_id, existing_site.name))
    if not read_yes_no("Confirm delete", false) then
        print("Cancelled.")
        return
    end

    local updated_by = read_line("Updated by", default_updated_by())
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

local function print_help()
    print("Commands:")
    print("  list")
    print("  add <site_id>")
    print("  edit <site_id>")
    print("  del <site_id>")
    print("  push")
    print("  help")
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
    print("Address book console ready. Type 'help' for commands.")

    while true do
        write("address-book> ")
        local line = read()
        local parts = tokenize(line)
        local command = parts[1]
        if command == nil then
        elseif command == "help" then
            print_help()
        else
            local handler = COMMAND_HANDLERS[command]
            if handler == nil then
                print_error("unknown command: " .. tostring(command))
                print_help()
            else
                handler(config, runtime, logger, parts[2])
            end
        end
    end
end

return console
