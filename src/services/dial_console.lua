local address_book = require("address_book")
local address_book_client = require("address_book.client")
local command_message = require("command.message")
local command_network = require("command.network")
local command_timeout = require("command.timeout")
local constants = require("core.constants")
local gate_capabilities = require("gate.capabilities")
local discovery = require("net.discovery")
local gate_message = require("gate.message")
local host_lifecycle = require("lifecycle.host")
local result = require("core.result")
local site_message = require("site.message")
local tablex = require("core.tablex")
local time = require("core.time")
local transport = require("net.rednet_transport")
local ui_monitor = require("ui.monitor")
local ui_term = require("ui.term")

local dial_console = {}
local UI_TICK_INTERVAL_SECONDS = 0.5
local NETWORK_RECEIVE_TIMEOUT_SECONDS = 0.25
local CANCELLED_PAGE_DURATION_MS = 4000
local GATE_STATE_STALE_MS = 8000
local STATE_FALLBACK_REQUEST_INTERVAL_MS = 3000
local MIN_MONITOR_WIDTH = 3
local MIN_MONITOR_HEIGHT = 1
local PEGASUS_STARGATE_GENERATION = 3
local INPUT_EVENT = "sgc_dial_console_input"
local NETWORK_EVENT = "sgc_dial_console_network"
local NETWORK_ERROR_EVENT = "sgc_dial_console_network_error"
local DIAL_MODE_CYCLE = {
    "auto",
    "slow",
    "medium",
    "fast",
}
local send_request
local current_page
local write_at
local blank_buffer
local print_terminal_feedback
local monitor_supports_color
local set_monitor_text_color

local INTERACTIVE_TERMINAL_COMMAND_SPECS = {
    {
        summary = "help",
        description = "Show available commands",
    },
    {
        summary = "<number|name>",
        description = "Dial a destination by number or exact name",
    },
    {
        summary = "mode <auto|slow|medium|fast>",
        description = "Set the preferred dial mode",
    },
    {
        summary = "refresh",
        description = "Refresh the address book cache",
    },
}

---@class SgcDialConsoleTopBar
---@field line string
---@field mode_x integer?
---@field mode_width integer
---@field mode_available boolean
---@field previous_x integer?
---@field next_x integer?

---@param prompt string
---@return SgcResult
local function read_line(prompt)
    if type(write) == "function" then
        write(prompt)
    else
        print(prompt)
    end

    if type(read) ~= "function" then
        return result.err("read_unavailable")
    end

    return result.ok(read())
end

---@param book SgcAddressBook
---@param site_id string
---@return SgcSiteEntry[]
local function visible_destinations(book, site_id)
    return address_book.list_visible_destinations(book, site_id)
end

---@param config table
---@param title string
---@param body string[]
---@return SgcResult
local function finish_without_crash(config, title, body)
    local monitor_side = config.modems ~= nil and config.modems.peripheral or nil
    if monitor_side ~= nil then
        ui_monitor.render(monitor_side, {
            "StargateCommand",
            "Dial Console",
            "",
            title,
            "",
            table.concat(body, " "),
        }, {
            text_scale = config.dial_console ~= nil and config.dial_console.monitor_text_scale
                or constants.DEFAULT_MONITOR_TEXT_SCALE,
        })
    end

    print("")
    print(title)
    for _, line in ipairs(body) do
        print(line)
    end

    return result.ok({
        active = false,
        title = title,
        lines = body,
    })
end

---@param address integer[]?
---@return integer[]
local function with_point_of_origin(address)
    if type(address) ~= "table" then
        return {}
    end

    if address[#address] == constants.POINT_OF_ORIGIN_SYMBOL then
        return address
    end

    local copy = {}
    for index, symbol in ipairs(address) do
        copy[index] = symbol
    end
    copy[#copy + 1] = constants.POINT_OF_ORIGIN_SYMBOL
    return copy
end

---@param address integer[]?
---@return string
local function format_address(address)
    if type(address) ~= "table" or #address == 0 then
        return "-"
    end

    return "-" .. table.concat(address, "-") .. "-"
end

---@param elapsed_ms integer?
---@return string
local function format_elapsed(elapsed_ms)
    local total_seconds = math.max(0, math.floor((elapsed_ms or 0) / 1000))
    local hours = math.floor(total_seconds / 3600)
    local minutes = math.floor((total_seconds % 3600) / 60)
    local seconds = total_seconds % 60
    return string.format("%02d:%02d:%02d", hours, minutes, seconds)
end

---@param text string
---@return string
local function trim(text)
    return tostring(text or ""):match("^%s*(.-)%s*$")
end

---@param text string
---@return string
local function normalized_text_key(text)
    return string.lower(trim(text))
end

---@param left string
---@param right string
---@param width integer
---@return string
local function top_bar(left, right, width)
    local left_text = tostring(left or "")
    local right_text = tostring(right or "")
    if width <= 0 then
        return ""
    end

    if #right_text >= width then
        return right_text:sub(#right_text - width + 1)
    end

    if #left_text + 1 + #right_text > width then
        local left_width = math.max(0, width - #right_text - 1)
        return left_text:sub(1, left_width) .. " " .. right_text
    end

    return left_text .. string.rep(" ", width - #left_text - #right_text) .. right_text
end

---@param current_mode SgcDialMode
---@return SgcDialMode
local function next_dial_mode(current_mode)
    for index, mode in ipairs(DIAL_MODE_CYCLE) do
        if mode == current_mode then
            return DIAL_MODE_CYCLE[index % #DIAL_MODE_CYCLE + 1]
        end
    end

    return constants.DEFAULT_DIAL_MODE
end

---@param runtime table
---@param dial_mode SgcDialMode
---@return boolean
local function dial_mode_available(runtime, dial_mode)
    if dial_mode == "auto" then
        return true
    end

    local gate_state = runtime.gate_state
    if type(gate_state) ~= "table" or type(gate_state.interface_type) ~= "string" then
        return true
    end

    local capabilities = gate_capabilities.for_type(gate_state.interface_type)
    if dial_mode == "fast" then
        return capabilities.direct_dial == true
    end

    if dial_mode == "medium" or dial_mode == "slow" then
        return capabilities.rotation == true
            and capabilities.chevron == true
            and capabilities.stargate_info == true
            and gate_state.stargate_generation ~= PEGASUS_STARGATE_GENERATION
    end

    return true
end

---@param config table
---@return number
local function monitor_text_scale(config)
    local dial_console_config = type(config) == "table" and config.dial_console or nil
    if type(dial_console_config) == "table" and type(dial_console_config.monitor_text_scale) == "number" then
        return dial_console_config.monitor_text_scale
    end

    return constants.DEFAULT_MONITOR_TEXT_SCALE
end

---@param config table
---@return string
local function fallback_terminal_label(config)
    return string.format("%s.%s", tostring(config.site), tostring(config.role))
end

---@param game_time number?
---@return string
local function format_game_time(game_time)
    if type(game_time) ~= "number" then
        return "--:--"
    end

    local normalized = game_time % 24
    if normalized < 0 then
        normalized = normalized + 24
    end

    local total_minutes = math.floor(normalized * 60)
    local hours = math.floor(total_minutes / 60) % 24
    local minutes = total_minutes % 60
    return string.format("%02d:%02d", hours, minutes)
end

---@return string
local function current_clock_label()
    local game_time = nil
    if os ~= nil and type(os.time) == "function" then
        local ok, value = pcall(os.time, "ingame")
        if ok and type(value) == "number" then
            game_time = value
        else
            ok, value = pcall(os.time)
            if ok and type(value) == "number" and value >= 0 and value < 24 then
                game_time = value
            end
        end
    end

    return string.format("%s [%s]", format_game_time(game_time), time.now_hms())
end

---@param activity string?
---@param fallback string?
---@return string
local function format_activity_label(activity, fallback)
    if type(activity) ~= "string" or activity == "" then
        return fallback or "-"
    end

    return activity:gsub("_", " ")
end

---@param runtime table
---@param fallback string?
---@return string
local function footer_text(runtime, fallback)
    if runtime.flash_message ~= nil and type(runtime.flash_message.text) == "string" then
        return runtime.flash_message.text
    end

    if type(runtime.last_gate_error) == "string" and runtime.last_gate_error ~= "" then
        return "Gate status: " .. runtime.last_gate_error
    end

    return fallback or ""
end

---@param line string
---@param width integer
---@return string
local function fit_line(line, width)
    local normalized = tostring(line or "")
    if #normalized <= width then
        return normalized .. string.rep(" ", width - #normalized)
    end

    if width <= 1 then
        return normalized:sub(1, width)
    end

    return normalized:sub(1, width - 1) .. ">"
end

---@param width integer
---@param text string
---@return string
local function bordered_alert_line(width, text)
    if width <= 0 then
        return ""
    end

    if width == 1 then
        return "!"
    end

    return "!" .. fit_line(" " .. tostring(text or ""), width - 2) .. "!"
end

---@param text string
---@param width integer
---@return string
local function centered_line(text, width)
    local normalized = tostring(text or "")
    if #normalized >= width then
        return fit_line(normalized, width)
    end

    local left_padding = math.floor((width - #normalized) / 2)
    local right_padding = width - #normalized - left_padding
    return string.rep(" ", left_padding) .. normalized .. string.rep(" ", right_padding)
end

---@param width integer
---@param left string?
---@param center string?
---@param right string?
---@return string
local function action_line(width, left, center, right)
    local buffer = blank_buffer(width, 1)
    local left_text = tostring(left or "")
    local center_text = tostring(center or "")
    local right_text = tostring(right or "")

    if left_text ~= "" then
        write_at(buffer, width, 1, 1, left_text)
    end

    if right_text ~= "" then
        write_at(buffer, width, math.max(1, width - #right_text + 1), 1, right_text)
    end

    if center_text ~= "" then
        write_at(buffer, width, math.max(1, math.floor((width - #center_text) / 2) + 1), 1, center_text)
    end

    return buffer[1]
end

---@param title string
---@param width integer
---@param alert boolean?
---@return string
local function page_title_line(title, width, alert)
    local spacer = " " .. tostring(title or "") .. " "
    local fill_character = alert == true and "!" or "="
    if #spacer >= width then
        return fit_line(title, width)
    end

    local left_fill = math.floor((width - #spacer) / 2)
    local right_fill = width - #spacer - left_fill
    return string.rep(fill_character, left_fill) .. spacer .. string.rep(fill_character, right_fill)
end

---@param label string
---@param value string
---@return string
local function detail_line(label, value)
    return string.format("%-9s %s", tostring(label) .. ":", tostring(value))
end

---@param runtime table
---@param width integer
---@param height integer
---@return integer, integer, integer, integer, integer
local function home_page_layout(runtime, width, height)
    local body_top = 2
    local footer_rows = height >= 2 and 1 or 0
    local body_bottom = height - footer_rows
    local rows = math.max(0, body_bottom - body_top + 1)
    local gutter = width >= 36 and 2 or 1
    local min_item_width = width >= 36 and 18 or 16
    local columns = math.max(1, math.floor((width + gutter) / (min_item_width + gutter)))
    local item_width = math.max(1, math.floor((width - (columns - 1) * gutter) / columns))
    local page_size = rows > 0 and rows * columns or 0
    local destination_count = #(runtime.destinations or {})
    local page_count = page_size > 0 and math.max(1, math.ceil(destination_count / page_size)) or 1
    return body_top, rows, columns, item_width, page_count
end

---@param runtime table
---@param width integer
---@param page_index integer?
---@param page_count integer?
---@return SgcDialConsoleTopBar
local function build_top_bar_spec(runtime, width, page_index, page_count)
    local mode_label = string.upper(runtime.selected_mode)
    local right_parts = {}
    if type(page_index) == "number" and type(page_count) == "number" and page_count > 1 then
        if page_index > 1 then
            right_parts[#right_parts + 1] = "<"
        end
        right_parts[#right_parts + 1] = string.format("%d/%d", page_index, page_count)
        if page_index < page_count then
            right_parts[#right_parts + 1] = ">"
        end
    end
    right_parts[#right_parts + 1] = mode_label

    local right_text = table.concat(right_parts, " ")
    local line = fit_line(top_bar(current_clock_label(), right_text, width), width)
    local right_start = math.max(1, width - #right_text + 1)
    local mode_x = math.max(right_start, width - #mode_label + 1)
    local mode_width = math.max(0, math.min(#mode_label, width - mode_x + 1))
    local previous_x = nil
    local next_x = nil
    local previous_offset = right_text:find("<", 1, true)
    local next_offset = right_text:find(">", 1, true)
    if previous_offset ~= nil then
        previous_x = right_start + previous_offset - 1
    end
    if next_offset ~= nil then
        next_x = right_start + next_offset - 1
    end

    return {
        line = line,
        mode_x = mode_width > 0 and mode_x or nil,
        mode_width = mode_width,
        mode_available = dial_mode_available(runtime, runtime.selected_mode),
        previous_x = previous_x,
        next_x = next_x,
    }
end

---@param runtime table
---@param width integer
---@param height integer
---@return integer
local function clamp_home_page(runtime, width, height)
    local _, _, _, _, page_count = home_page_layout(runtime, width, height)
    local requested = type(runtime.home_page_index) == "number" and runtime.home_page_index or 1
    local clamped = math.max(1, math.min(page_count, math.floor(requested)))
    runtime.home_page_index = clamped
    return clamped
end

---@param runtime table
---@param width integer
---@param height integer
---@param title string
---@param headline string
---@param detail_lines string[]
---@param footer string
---@param alert boolean?
---@return string[]
local function render_detail_page(runtime, width, height, title, headline, detail_lines, footer, alert)
    local buffer = blank_buffer(width, height)
    runtime.monitor_top_bar = build_top_bar_spec(runtime, width, nil, nil)
    buffer[1] = runtime.monitor_top_bar.line
    if height >= 2 then
        buffer[2] = page_title_line(title, width, alert)
    end

    local body_lines = { centered_line(headline, width) }
    for _, line in ipairs(detail_lines) do
        body_lines[#body_lines + 1] = fit_line(line, width)
    end

    local row = 3
    local max_body_row = height >= 3 and math.max(2, height - 1) or 1
    for _, line in ipairs(body_lines) do
        if row > max_body_row then
            break
        end

        buffer[row] = line
        row = row + 1
    end

    if height >= 2 then
        buffer[height] = fit_line(footer, width)
    end
    return buffer
end

---@param buffer string[]
---@param width integer
---@param x integer
---@param y integer
---@param text string
write_at = function(buffer, width, x, y, text)
    if y < 1 or y > #buffer or x > width then
        return
    end

    local prefix = buffer[y]:sub(1, math.max(0, x - 1))
    local suffix_start = x + #text
    local suffix = suffix_start <= width and buffer[y]:sub(suffix_start) or ""
    local available = math.max(0, width - x + 1)
    local clipped = tostring(text or ""):sub(1, available)
    buffer[y] = (prefix .. clipped .. suffix):sub(1, width)
    if #buffer[y] < width then
        buffer[y] = buffer[y] .. string.rep(" ", width - #buffer[y])
    end
end

---@param width integer
---@param height integer
---@return string[]
blank_buffer = function(width, height)
    local lines = {}
    for index = 1, height do
        lines[index] = string.rep(" ", width)
    end
    return lines
end

---@param runtime table
---@param text string
---@param duration_ms integer?
local function set_flash_message(runtime, text, duration_ms)
    runtime.flash_message = {
        text = text,
        expires_at = duration_ms ~= nil and (time.now_ms() + duration_ms) or nil,
    }
end

---@param book SgcAddressBook
---@param selection string
---@param site_id string
---@return SgcResult
local function resolve_destination_selection(book, selection, site_id)
    local destinations = visible_destinations(book, site_id)
    local numeric_choice = tonumber(selection)
    if numeric_choice ~= nil and numeric_choice % 1 == 0 then
        local indexed = destinations[numeric_choice]
        if indexed ~= nil then
            return result.ok(indexed)
        end
    end

    local normalized_selection = normalized_text_key(selection)
    for _, destination in ipairs(destinations) do
        if destination.id == selection or normalized_text_key(destination.name) == normalized_selection then
            return result.ok(destination)
        end
    end

    return result.err("unknown_destination_selection", {
        selection = selection,
    })
end

---@param left integer[]?
---@param right integer[]?
---@return boolean
local function addresses_equal(left, right)
    if type(left) ~= "table" or type(right) ~= "table" or #left ~= #right then
        return false
    end

    for index, value in ipairs(left) do
        if right[index] ~= value then
            return false
        end
    end

    return true
end

---@param book SgcAddressBook
---@param address integer[]?
---@return SgcSiteEntry?
local function find_site_by_address(book, address)
    if type(book) ~= "table" or type(book.sites) ~= "table" or type(address) ~= "table" then
        return nil
    end

    for _, site in pairs(book.sites) do
        if type(site) == "table" and type(site.addresses) == "table" then
            if addresses_equal(site.addresses.system, address)
                or addresses_equal(site.addresses.stellar, address)
                or addresses_equal(site.addresses.galactic, address)
            then
                return site
            end
        end
    end

    return nil
end

---@param runtime table
---@return boolean
local function gate_is_incoming(runtime)
    local gate_state = runtime.gate_state
    return type(gate_state) == "table"
        and gate_state.connection_direction == "incoming"
        and gate_state.activity ~= "idle"
end

---@param runtime table
---@return boolean
local function gate_is_outgoing(runtime)
    local gate_state = runtime.gate_state
    return type(gate_state) == "table"
        and gate_state.connection_direction == "outgoing"
        and gate_state.activity ~= "idle"
end

---@param runtime table
---@return boolean
local function gate_is_connected(runtime)
    return type(runtime.gate_state) == "table" and runtime.gate_state.connected == true
end

---@param runtime table
---@return boolean
local function gate_has_live_connection(runtime)
    local gate_state = runtime.gate_state
    if type(gate_state) ~= "table" then
        return false
    end

    return gate_state.connected == true
        or gate_state.open == true
        or gate_state.activity == "incoming_open"
        or gate_state.activity == "incoming_connected"
        or gate_state.activity == "outgoing_open"
        or gate_state.activity == "outgoing_connected"
end

---@param runtime table
---@return boolean
local function dial_request_in_flight(runtime)
    return runtime.pending_dial_reply ~= nil or runtime.pending_dial ~= nil
end

---@param runtime table
---@param gate_state table?
local function update_gate_state(runtime, gate_state)
    runtime.gate_state = gate_state
    runtime.last_gate_state_at = type(gate_state) == "table" and time.now_ms() or nil
end

---@param runtime table
local function clear_pending_status_request(runtime)
    if runtime.pending_status ~= nil then
        runtime.pending_requests[runtime.pending_status.request_id] = nil
        runtime.pending_status = nil
    end
end

---@param runtime table
---@param gate_state table
---@param sequence integer?
---@return boolean
local function apply_gate_state_snapshot(runtime, gate_state, sequence)
    if type(sequence) == "number"
        and type(runtime.last_gate_state_sequence) == "number"
        and sequence <= runtime.last_gate_state_sequence
    then
        return false
    end

    update_gate_state(runtime, gate_state)
    if type(sequence) == "number" then
        runtime.last_gate_state_sequence = sequence
    end
    clear_pending_status_request(runtime)
    runtime.last_gate_error = nil
    return true
end

---@param runtime table
---@param gate_state table
---@return boolean
local function apply_gate_state_reply_snapshot(runtime, gate_state)
    if type(runtime.last_gate_state_sequence) == "number" and type(runtime.gate_state) == "table" then
        return false
    end

    return apply_gate_state_snapshot(runtime, gate_state, nil)
end

---@param runtime table
local function clear_pending_dial_request(runtime)
    if runtime.pending_dial_reply ~= nil then
        runtime.pending_requests[runtime.pending_dial_reply.request_id] = nil
        runtime.pending_dial_reply = nil
    end
end

---@param runtime table
local function clear_pending_disconnect_request(runtime)
    if runtime.pending_disconnect_reply ~= nil then
        runtime.pending_requests[runtime.pending_disconnect_reply.request_id] = nil
        runtime.pending_disconnect_reply = nil
    end
end

---@param runtime table
local function complete_cancelled_dial(runtime)
    local cancelled_session = runtime.outgoing_session or runtime.pending_dial or runtime.cancelled_session
    clear_pending_dial_request(runtime)
    clear_pending_disconnect_request(runtime)
    clear_pending_status_request(runtime)
    runtime.last_dial_result = nil
    runtime.last_gate_error = nil
    runtime.pending_dial = nil
    runtime.cancel_requested = false
    runtime.cancelled_session = cancelled_session
    runtime.cancelled_until = time.now_ms() + CANCELLED_PAGE_DURATION_MS
    runtime.outgoing_session = nil
    runtime.outgoing_connected_at = nil
    set_flash_message(runtime, "Dial cancelled", 3000)
end

---@param runtime table
local function update_session_state(runtime)
    local now_ms = time.now_ms()

    if runtime.last_gate_state_at ~= nil and now_ms - runtime.last_gate_state_at > GATE_STATE_STALE_MS then
        update_gate_state(runtime, nil)
        runtime.last_gate_state_sequence = nil
        if not dial_request_in_flight(runtime) then
            runtime.outgoing_session = nil
            runtime.outgoing_connected_at = nil
            runtime.pending_dial = nil
        end
        runtime.incoming_session = nil
        runtime.incoming_connected_at = nil
    end

    local gate_state = runtime.gate_state

    if gate_is_outgoing(runtime) then
        runtime.outgoing_session = runtime.outgoing_session or runtime.pending_dial
        if gate_has_live_connection(runtime) and runtime.outgoing_connected_at == nil then
            runtime.outgoing_connected_at = now_ms
        end
    elseif dial_request_in_flight(runtime) then
        runtime.outgoing_session = runtime.outgoing_session or runtime.pending_dial
        runtime.outgoing_connected_at = nil
    else
        runtime.outgoing_connected_at = nil
        runtime.outgoing_session = nil
        runtime.pending_dial = nil
    end

    if gate_is_incoming(runtime) then
        local incoming_address = nil
        if type(gate_state) == "table" then
            incoming_address = gate_state.connected_address or gate_state.dialed_address
        end

        runtime.incoming_session = {
            address = incoming_address,
            site = find_site_by_address(runtime.book, incoming_address),
        }
        if gate_has_live_connection(runtime) and runtime.incoming_connected_at == nil then
            runtime.incoming_connected_at = now_ms
        end
    else
        runtime.incoming_session = nil
        runtime.incoming_connected_at = nil
    end

    if runtime.pending_dial_reply ~= nil and runtime.pending_dial_reply.expires_at <= now_ms then
        if runtime.cancel_requested == true then
            complete_cancelled_dial(runtime)
        else
            clear_pending_dial_request(runtime)
            runtime.pending_dial = nil
            runtime.outgoing_session = nil
            runtime.outgoing_connected_at = nil
            runtime.cancel_requested = false
            set_flash_message(runtime, "Dial timed out", nil)
        end
    end

    if runtime.pending_disconnect_reply ~= nil and runtime.pending_disconnect_reply.expires_at <= now_ms then
        if runtime.cancel_requested == true then
            complete_cancelled_dial(runtime)
        else
            clear_pending_disconnect_request(runtime)
            set_flash_message(runtime, "Disconnect timed out", nil)
        end
    end

    if runtime.pending_status ~= nil and runtime.pending_status.expires_at <= now_ms then
        runtime.pending_requests[runtime.pending_status.request_id] = nil
        if not dial_request_in_flight(runtime)
            and runtime.pending_disconnect_reply == nil
            and runtime.outgoing_session == nil
            and runtime.incoming_session == nil
        then
            runtime.last_gate_error = "command_timeout"
        end
        runtime.pending_status = nil
    end

    if runtime.cancelled_until ~= nil and runtime.cancelled_until <= now_ms then
        runtime.cancelled_until = nil
        runtime.cancelled_session = nil
    end

    if runtime.flash_message ~= nil
        and runtime.flash_message.expires_at ~= nil
        and runtime.flash_message.expires_at <= now_ms
    then
        runtime.flash_message = nil
    end
end

---@param runtime table
---@return string
current_page = function(runtime)
    if runtime.cancelled_until ~= nil and runtime.cancelled_until > time.now_ms() then
        return "cancelled"
    end

    if gate_is_incoming(runtime) then
        if gate_has_live_connection(runtime) then
            return "incoming_connected"
        end

        return "incoming_alert"
    end

    if gate_is_outgoing(runtime) then
        if gate_has_live_connection(runtime) then
            return "outgoing_connected"
        end

        return "dialing_out"
    end

    if dial_request_in_flight(runtime) then
        return "dialing_out"
    end

    return "home"
end

---@param runtime table
---@return boolean
local function suppress_background_status_poll(runtime)
    return dial_request_in_flight(runtime) or runtime.cancel_requested == true
end

---@param runtime table
---@return string
local function source_site_name(runtime)
    if runtime.incoming_session ~= nil and runtime.incoming_session.site ~= nil then
        return runtime.incoming_session.site.name
    end

    return "Unknown Origin"
end

---@param runtime table
---@return integer[]?
local function actual_outgoing_address(runtime)
    if runtime.outgoing_session ~= nil and type(runtime.outgoing_session.address) == "table" then
        return with_point_of_origin(runtime.outgoing_session.address)
    end

    local gate_state = runtime.gate_state
    if type(gate_state) == "table" then
        if type(gate_state.connected_address) == "table" then
            return gate_state.connected_address
        end

        if type(gate_state.dialed_address) == "table" then
            return gate_state.dialed_address
        end
    end

    return nil
end

---@param runtime table
---@return string
local function target_site_name(runtime)
    if runtime.outgoing_session ~= nil and runtime.outgoing_session.name ~= nil then
        return runtime.outgoing_session.name
    end

    local site = find_site_by_address(runtime.book, actual_outgoing_address(runtime))
    if site ~= nil and site.name ~= nil then
        return site.name
    end

    return "Unknown Destination"
end

---@param runtime table
---@return integer[]
local function target_address(runtime)
    local address = actual_outgoing_address(runtime)
    if type(address) == "table" then
        return address
    end

    return {}
end

---@class SgcOutgoingProgressHighlight
---@field index integer
---@field exact boolean

---@class SgcOutgoingProgressState
---@field engaged integer
---@field highlight SgcOutgoingProgressHighlight?

---@param address integer[]
---@param symbol integer?
---@param start_index integer
---@return integer?
local function matching_outgoing_symbol_index(address, symbol, start_index)
    if type(symbol) ~= "number" or symbol == constants.POINT_OF_ORIGIN_SYMBOL then
        return nil
    end

    for index = math.max(1, start_index), #address do
        if address[index] == symbol then
            return index
        end
    end

    return nil
end

---@param runtime table
---@return "direct" | "rotating"
local function outgoing_progress_style(runtime)
    if runtime.selected_mode == "fast" then
        return "direct"
    end

    if runtime.selected_mode == "medium" or runtime.selected_mode == "slow" then
        return "rotating"
    end

    local gate_state = runtime.gate_state
    if type(gate_state) ~= "table" or type(gate_state.interface_type) ~= "string" then
        return "rotating"
    end

    local capabilities = gate_capabilities.for_type(gate_state.interface_type)
    return capabilities.direct_dial == true and "direct" or "rotating"
end

---@param runtime table
---@param address integer[]
---@param engaged_override integer?
---@return SgcOutgoingProgressState
local function outgoing_progress_state(runtime, address, engaged_override)
    local gate_state = runtime.gate_state or {}
    local progress = type(engaged_override) == "number"
            and engaged_override
        or type(gate_state.chevrons_engaged) == "number" and gate_state.chevrons_engaged
        or 0
    local engaged = math.max(0, math.min(progress, #address))
    if gate_has_live_connection(runtime) then
        return {
            engaged = #address,
            highlight = nil,
        }
    end

    local style = outgoing_progress_style(runtime)
    local current_index = style == "rotating"
        and matching_outgoing_symbol_index(address, gate_state.current_symbol, engaged + 1)
        or nil

    local highlight = nil
    if current_index ~= nil then
        highlight = {
            index = current_index,
            exact = true,
        }
    elseif engaged < #address and address[engaged + 1] ~= constants.POINT_OF_ORIGIN_SYMBOL then
        highlight = {
            index = engaged + 1,
            exact = false,
        }
    end

    return {
        engaged = engaged,
        highlight = highlight,
    }
end

---@param runtime table
---@param address integer[]
---@return integer
local function engaged_outgoing_progress(runtime, address)
    return outgoing_progress_state(runtime, address).engaged
end

---@param runtime table
---@param address integer[]
---@param engaged_progress integer
---@return SgcOutgoingProgressHighlight?
local function outgoing_progress_highlight(runtime, address, engaged_progress)
    return outgoing_progress_state(runtime, address, engaged_progress).highlight
end

---@param runtime table
---@param width integer
---@param height integer
---@return string[]
local function render_home_page(runtime, width, height)
    local buffer = blank_buffer(width, height)
    local destinations = runtime.destinations
    local body_top, rows, columns, item_width, page_count = home_page_layout(runtime, width, height)
    local page_index = clamp_home_page(runtime, width, height)
    runtime.monitor_top_bar = build_top_bar_spec(runtime, width, page_index, page_count)
    buffer[1] = runtime.monitor_top_bar.line
    runtime.monitor_touch_targets = {
        mode = runtime.monitor_top_bar.mode_x ~= nil and {
            x = runtime.monitor_top_bar.mode_x,
            y = 1,
            width = runtime.monitor_top_bar.mode_width,
            height = 1,
        } or nil,
        previous_page = runtime.monitor_top_bar.previous_x ~= nil and {
            x = runtime.monitor_top_bar.previous_x,
            y = 1,
            width = 1,
            height = 1,
        } or nil,
        next_page = runtime.monitor_top_bar.next_x ~= nil and {
            x = runtime.monitor_top_bar.next_x,
            y = 1,
            width = 1,
            height = 1,
        } or nil,
        destinations = {},
    }

    if #destinations == 0 then
        if height >= 2 then
            buffer[2] = centered_line("No destinations", width)
            buffer[height] = fit_line(footer_text(runtime, "Refresh address book to retry"), width)
        end
        return buffer
    end

    local page_size = rows * columns
    local page_offset = (page_index - 1) * page_size
    local gutter = width >= 36 and 2 or 1
    for row = 0, rows - 1 do
        for column = 0, columns - 1 do
            local index = page_offset + row * columns + column + 1
            local destination = destinations[index]
            if destination == nil then
                break
            end

            local x = column * (item_width + gutter) + 1
            local y = body_top + row
            local touch_width = math.min(item_width, width - x + 1)
            local destination_label = string.format("%d. %s", index, destination.name)
            write_at(buffer, width, x, y, fit_line(destination_label, item_width))

            runtime.monitor_touch_targets.destinations[#runtime.monitor_touch_targets.destinations + 1] = {
                x = x,
                y = y,
                width = touch_width,
                height = 1,
                destination = destination,
            }
        end
    end

    if height >= 2 then
        local default_footer = page_count > 1
                and "Tap destination; use Prev/Next for more"
            or "Tap destination to dial"
        buffer[height] = fit_line(footer_text(runtime, default_footer), width)
    end

    return buffer
end

---@param runtime table
---@param width integer
---@param height integer
---@return string[]
local function render_cancelled_page(runtime, width, height)
    local cancelled_session = runtime.cancelled_session or {}
    local address = cancelled_session.address or {}
    return render_detail_page(runtime, width, height, "DIAL CANCELLED", tostring(cancelled_session.name or "Unknown Destination"), {
        "",
        detail_line("Address", format_address(address)),
        "",
        "Returning home...",
    }, footer_text(runtime, ""), false)
end

---@param runtime table
---@param width integer
---@param height integer
---@return string[]
local function render_outgoing_page(runtime, width, height)
    local gate_state = runtime.gate_state or {}
    local address = target_address(runtime)
    local progress_state = outgoing_progress_state(runtime, address)
    local detail_lines = {
        "",
        detail_line("Address", format_address(address)),
        detail_line("Chevrons", string.format("%d/%d", progress_state.engaged, #address)),
        detail_line("State", format_activity_label(gate_state.activity, "pending")),
    }

    return render_detail_page(
        runtime,
        width,
        height,
        "DIALING OUT",
        target_site_name(runtime),
        detail_lines,
        footer_text(runtime, "Touch monitor to cancel"),
        false
    )
end

---@param runtime table
---@param width integer
---@param height integer
---@return string[]
local function render_outgoing_connected_page(runtime, width, height)
    local connected_at = runtime.outgoing_connected_at or time.now_ms()
    local gate_state = runtime.gate_state or {}
    return render_detail_page(runtime, width, height, "OUTGOING LINK", target_site_name(runtime), {
        "",
        detail_line("Address", format_address(target_address(runtime))),
        detail_line("Elapsed", format_elapsed(time.now_ms() - connected_at)),
        detail_line("State", format_activity_label(gate_state.activity, "connected")),
    }, footer_text(runtime, "Touch monitor to disconnect"), false)
end

---@param runtime table
---@param width integer
---@param height integer
---@return string[]
local function render_incoming_alert_page(runtime, width, height)
    return render_detail_page(
        runtime,
        width,
        height,
        "INCOMING ALERT",
        source_site_name(runtime),
        {
            "",
            detail_line(
                "State",
                format_activity_label(runtime.gate_state ~= nil and runtime.gate_state.activity or nil, "awaiting lock")
            ),
        },
        footer_text(runtime, "Awaiting connection"),
        true
    )
end

---@param runtime table
---@param width integer
---@param height integer
---@return string[]
local function render_incoming_connected_page(runtime, width, height)
    local connected_at = runtime.incoming_connected_at or time.now_ms()
    local gate_state = runtime.gate_state or {}
    return render_detail_page(
        runtime,
        width,
        height,
        "INCOMING LINK",
        source_site_name(runtime),
        {
            "",
            detail_line("Elapsed", format_elapsed(time.now_ms() - connected_at)),
            detail_line("State", format_activity_label(gate_state.activity, "connected")),
        },
        footer_text(runtime, "Touch monitor to disconnect"),
        true
    )
end

---@param terminal table
---@param width integer
---@param row integer
---@param text string
local function write_monitor_line(terminal, width, row, text)
    terminal.setCursorPos(1, row)
    terminal.write(fit_line(text or "", width))
end

---@param terminal table
---@param width integer
---@param row integer
---@param top_bar SgcDialConsoleTopBar?
local function write_monitor_top_bar_line(terminal, width, row, top_bar)
    local line = type(top_bar) == "table" and top_bar.line or ""
    local normalized = fit_line(line, width)
    if type(top_bar) ~= "table"
        or not monitor_supports_color(terminal)
        or type(colors) ~= "table"
        or top_bar.mode_available ~= false
        or type(top_bar.mode_x) ~= "number"
        or type(top_bar.mode_width) ~= "number"
        or top_bar.mode_width <= 0
    then
        write_monitor_line(terminal, width, row, normalized)
        return
    end

    local unavailable_color = colors.lightGray or colors.gray or colors.white
    local before = normalized:sub(1, top_bar.mode_x - 1)
    local mode_text = normalized:sub(top_bar.mode_x, top_bar.mode_x + top_bar.mode_width - 1)
    local after = normalized:sub(top_bar.mode_x + top_bar.mode_width)

    terminal.setCursorPos(1, row)
    set_monitor_text_color(terminal, colors.white or unavailable_color)
    terminal.write(before)
    set_monitor_text_color(terminal, unavailable_color)
    terminal.write(mode_text)
    set_monitor_text_color(terminal, colors.white or unavailable_color)
    terminal.write(after)
end

---@param terminal table
---@param width integer
---@param row integer
---@param text string
local function write_monitor_incoming_connected_line(terminal, width, row, text)
    local normalized = fit_line(text or "", width)
    if not monitor_supports_color(terminal)
        or type(colors) ~= "table"
        or normalized:find("!", 1, true) == nil
    then
        write_monitor_line(terminal, width, row, normalized)
        return
    end

    local fill_color = colors.red or colors.white
    local separator_color = colors.white or fill_color
    local current_color = nil
    local chunk = ""

    terminal.setCursorPos(1, row)
    for index = 1, #normalized do
        local character = normalized:sub(index, index)
        local wanted_color = (character == "!" or character == " ") and separator_color or fill_color
        if current_color == nil then
            current_color = wanted_color
        end

        if wanted_color ~= current_color then
            set_monitor_text_color(terminal, current_color)
            terminal.write(chunk)
            chunk = ""
            current_color = wanted_color
        end

        chunk = chunk .. character
    end

    if #chunk > 0 then
        set_monitor_text_color(terminal, current_color or separator_color)
        terminal.write(chunk)
    end

    set_monitor_text_color(terminal, colors.white or separator_color)
end

---@param terminal table
---@return boolean
monitor_supports_color = function(terminal)
    if type(terminal.isColor) == "function" then
        local ok, supports_color = pcall(terminal.isColor)
        if ok then
            return supports_color == true
        end
    end

    if type(terminal.isColour) == "function" then
        local ok, supports_color = pcall(terminal.isColour)
        if ok then
            return supports_color == true
        end
    end

    return type(terminal.setTextColor) == "function" or type(terminal.setTextColour) == "function"
end

---@param terminal table
---@param color integer
set_monitor_text_color = function(terminal, color)
    if type(terminal.setTextColor) == "function" then
        terminal.setTextColor(color)
    elseif type(terminal.setTextColour) == "function" then
        terminal.setTextColour(color)
    end
end

---@param terminal table
---@param width integer
---@param row integer
---@param address integer[]
---@param engaged_progress integer
---@param highlight SgcOutgoingProgressHighlight?
local function render_outgoing_address_progress(terminal, width, row, address, engaged_progress, highlight)
    local line_prefix = "Address: "
    if not monitor_supports_color(terminal) or type(colors) ~= "table" then
        write_monitor_line(terminal, width, row, line_prefix .. format_address(address))
        return
    end

    local available = width - #line_prefix
    if available <= 0 then
        write_monitor_line(terminal, width, row, line_prefix)
        return
    end

    local engaged_color = colors.lime or colors.white
    local exact_current_color = colors.yellow or engaged_color
    local inferred_current_color = colors.orange or exact_current_color
    local pending_color = colors.gray or colors.lightGray or colors.white
    local separator_color = colors.white
    local clamped_progress = math.max(0, math.min(engaged_progress, #address))
    local highlighted_index = type(highlight) == "table" and highlight.index or nil
    local written = 0

    terminal.setCursorPos(1, row)
    set_monitor_text_color(terminal, separator_color)
    terminal.write(line_prefix)

    for index, symbol in ipairs(address) do
        if written >= available then
            break
        end

        set_monitor_text_color(terminal, separator_color)
        terminal.write("-")
        written = written + 1
        if written >= available then
            break
        end

        local symbol_text = tostring(symbol)
        local remaining = available - written
        local clipped_symbol = symbol_text:sub(1, remaining)
        local symbol_color = pending_color
        if index <= clamped_progress then
            symbol_color = engaged_color
        elseif highlighted_index == index then
            symbol_color = highlight.exact == true and exact_current_color or inferred_current_color
        end
        set_monitor_text_color(terminal, symbol_color)
        terminal.write(clipped_symbol)
        written = written + #clipped_symbol
        if #clipped_symbol < #symbol_text then
            break
        end
    end

    if written < available then
        set_monitor_text_color(terminal, separator_color)
        terminal.write("-")
        written = written + 1
    end

    if written < available then
        terminal.write(string.rep(" ", available - written))
    end

    set_monitor_text_color(terminal, colors.white or separator_color)
end

---@param runtime table
local function reset_monitor_session(runtime)
    runtime.monitor_session = nil
    runtime.monitor_id = nil
    runtime.monitor_touch_targets = nil
end

---@param runtime table
---@return SgcResult
local function ensure_monitor_session(runtime)
    local monitor_side = runtime.config.modems ~= nil and runtime.config.modems.peripheral or nil
    if monitor_side == nil then
        reset_monitor_session(runtime)
        return result.err("missing_monitor")
    end

    local text_scale = monitor_text_scale(runtime.config)
    if type(runtime.monitor_session) == "table"
        and runtime.monitor_session.side == monitor_side
        and runtime.monitor_session.text_scale == text_scale
    then
        return result.ok(runtime.monitor_session)
    end

    local opened = ui_monitor.open(monitor_side, {
        text_scale = text_scale,
    })
    if not opened.ok then
        reset_monitor_session(runtime)
        return opened
    end

    runtime.monitor_session = {
        side = monitor_side,
        text_scale = text_scale,
        terminal = opened.value.terminal,
        width = math.max(MIN_MONITOR_WIDTH, opened.value.width or 20),
        height = math.max(MIN_MONITOR_HEIGHT, opened.value.height or 12),
        id = opened.value.id,
        last_lines = nil,
        last_progress_signature = nil,
    }
    runtime.monitor_id = opened.value.id
    return result.ok(runtime.monitor_session)
end

---@param runtime table
local function render_monitor(runtime)
    local ensured = ensure_monitor_session(runtime)
    if not ensured.ok then
        return
    end

    local session = ensured.value
    local terminal = session.terminal
    local width = session.width
    local height = session.height
    runtime.monitor_id = session.id
    runtime.monitor_touch_targets = nil
    runtime.monitor_top_bar = nil
    local page = current_page(runtime)
    local lines = nil
    if page == "cancelled" then
        lines = render_cancelled_page(runtime, width, height)
    elseif page == "dialing_out" then
        lines = render_outgoing_page(runtime, width, height)
    elseif page == "outgoing_connected" then
        lines = render_outgoing_connected_page(runtime, width, height)
    elseif page == "incoming_alert" then
        lines = render_incoming_alert_page(runtime, width, height)
    elseif page == "incoming_connected" then
        lines = render_incoming_connected_page(runtime, width, height)
    else
        lines = render_home_page(runtime, width, height)
    end

    local previous_lines = session.last_lines or {}
    local top_bar_signature = nil
    if type(runtime.monitor_top_bar) == "table" then
        top_bar_signature = tostring(runtime.monitor_top_bar.line)
            .. "|"
            .. tostring(runtime.monitor_top_bar.mode_x)
            .. "|"
            .. tostring(runtime.monitor_top_bar.mode_width)
            .. "|"
            .. tostring(runtime.monitor_top_bar.mode_available)
    end
    if page == "incoming_connected" or page == "incoming_alert" then
        for row = 1, height do
            local line = lines[row] or ""
            if row == 1 then
                if previous_lines[row] ~= line or session.last_top_bar_signature ~= top_bar_signature then
                    write_monitor_top_bar_line(terminal, width, row, runtime.monitor_top_bar)
                end
            elseif previous_lines[row] ~= line then
                write_monitor_incoming_connected_line(terminal, width, row, line)
            end
        end
    else
        for row = 1, height do
            local line = lines[row] or ""
            if row == 1 then
                if previous_lines[row] ~= line or session.last_top_bar_signature ~= top_bar_signature then
                    write_monitor_top_bar_line(terminal, width, row, runtime.monitor_top_bar)
                end
            elseif previous_lines[row] ~= line then
                write_monitor_line(terminal, width, row, line)
            end
        end
    end

    local progress_signature = nil
    if page == "dialing_out" or page == "outgoing_connected" then
        local address = target_address(runtime)
        local engaged_progress = engaged_outgoing_progress(runtime, address)
        local highlight = outgoing_progress_highlight(runtime, address, engaged_progress)
        progress_signature = table.concat(address, ",")
            .. "|"
            .. tostring(engaged_progress)
            .. "|"
            .. tostring(highlight ~= nil and highlight.index or nil)
            .. "|"
            .. tostring(highlight ~= nil and highlight.exact or nil)
            .. "|"
            .. tostring(width)
        if session.last_progress_signature ~= progress_signature then
            render_outgoing_address_progress(terminal, width, 5, address, engaged_progress, highlight)
        end
    end

    if runtime.flash_message ~= nil and height >= 1 then
        write_monitor_line(terminal, width, height, runtime.flash_message.text)
    end

    session.last_lines = tablex.deep_copy(lines)
    session.last_progress_signature = progress_signature
    session.last_top_bar_signature = top_bar_signature
end

---@param runtime table
---@param destination SgcSiteEntry
---@param announce boolean?
local function request_dial(runtime, destination, announce)
    local dial_request = send_request(runtime, "site_controller", {
        action = "dial",
        destination_site = destination.id,
        dial_mode = runtime.selected_mode,
    }, "dial", command_timeout.for_action("dial"), {
        destination_site = destination.id,
    })
    if not dial_request.ok then
        if announce ~= false then
            print_terminal_feedback(runtime, "Dial request failed: " .. tostring(dial_request.error))
        else
            set_flash_message(runtime, "Dial failed: " .. tostring(dial_request.error), nil)
        end
        return
    end

    runtime.outgoing_session = {
        id = destination.id,
        name = destination.name,
        address = address_book.get_best_address(runtime.book, runtime.config.site, destination.id),
        requested_at = time.now_ms(),
    }
    runtime.pending_dial = runtime.outgoing_session
    runtime.cancelled_session = nil
    runtime.cancelled_until = nil
    runtime.cancel_requested = false
    runtime.flash_message = nil

    if announce ~= false then
        print_terminal_feedback(runtime, "Dialing " .. tostring(destination.name))
    end
end

---@param runtime table
---@param announce boolean?
---@return SgcResult
local function request_disconnect(runtime, announce)
    if runtime.pending_disconnect_reply ~= nil then
        return result.ok(false)
    end

    local disconnect_request = send_request(runtime, "site_controller", {
        action = "disconnect",
    }, "disconnect", command_timeout.for_action("disconnect"))
    if not disconnect_request.ok then
        if announce ~= false then
            print_terminal_feedback(runtime, "Disconnect request failed: " .. tostring(disconnect_request.error))
        else
            set_flash_message(runtime, "Disconnect failed: " .. tostring(disconnect_request.error), nil)
        end
        return disconnect_request
    end

    set_flash_message(runtime, "Disconnecting", 3000)
    return result.ok(true)
end

---@param runtime table
local function cancel_outgoing_dial(runtime)
    if current_page(runtime) ~= "dialing_out" then
        return
    end

    local disconnect_requested = request_disconnect(runtime, false)
    if disconnect_requested.ok then
        runtime.cancel_requested = true
        set_flash_message(runtime, "Cancel requested", 3000)
    end
end

---@param target table?
---@param x integer
---@param y integer
---@return boolean
local function point_in_target(target, x, y)
    return type(target) == "table"
        and type(target.x) == "number"
        and type(target.y) == "number"
        and type(target.width) == "number"
        and type(target.height) == "number"
        and x >= target.x
        and x < target.x + target.width
        and y >= target.y
        and y < target.y + target.height
end

---@param runtime table
---@param monitor_id string
---@param x integer
---@param y integer
local function handle_monitor_touch(runtime, monitor_id, x, y)
    if runtime.monitor_id == nil
        or runtime.monitor_id ~= monitor_id
        or type(x) ~= "number"
        or type(y) ~= "number"
    then
        return
    end

    if runtime.flash_message ~= nil and runtime.flash_message.expires_at == nil then
        runtime.flash_message = nil
        return
    end

    local page = current_page(runtime)
    if page == "dialing_out" then
        cancel_outgoing_dial(runtime)
        return
    end

    if page == "outgoing_connected" or page == "incoming_connected" then
        request_disconnect(runtime, false)
        return
    end

    if page ~= "home" then
        return
    end

    local targets = runtime.monitor_touch_targets
    if type(targets) ~= "table" then
        return
    end

    if point_in_target(targets.mode, x, y) then
        runtime.selected_mode = next_dial_mode(runtime.selected_mode)
        set_flash_message(runtime, "Dial mode: " .. runtime.selected_mode, 1500)
        return
    end

    if point_in_target(targets.previous_page, x, y) then
        runtime.home_page_index = math.max(1, (runtime.home_page_index or 1) - 1)
        return
    end

    if point_in_target(targets.next_page, x, y) then
        runtime.home_page_index = (runtime.home_page_index or 1) + 1
        return
    end

    for _, target in ipairs(targets.destinations or {}) do
        if point_in_target(target, x, y) then
            request_dial(runtime, target.destination, false)
            return
        end
    end
end

---@param runtime table
---@param target_role "site_controller"|"gate_controller"
---@param command_payload table
---@param kind "dial"|"disconnect"|"gate_status"
---@param timeout_seconds number
---@param context table?
---@return SgcResult
send_request = function(runtime, target_role, command_payload, kind, timeout_seconds, context)
    local payload = target_role == "gate_controller"
        and command_message.build_gate_request_payload(runtime.config.site, command_payload)
        or command_message.build_site_request_payload(runtime.config.site, command_payload)
    local sent = command_network.broadcast_command(runtime.config, payload)
    if not sent.ok then
        return sent
    end

    runtime.pending_requests[sent.value.msg_id] = {
        kind = kind,
        target_role = target_role,
        command = command_payload,
        sent_at = time.now_ms(),
        expires_at = time.now_ms() + math.floor(timeout_seconds * 1000),
        context = context,
    }

    if kind == "gate_status" then
        runtime.pending_status = {
            request_id = sent.value.msg_id,
            expires_at = time.now_ms() + math.floor(timeout_seconds * 1000),
        }
    elseif kind == "dial" then
        runtime.pending_dial_reply = {
            request_id = sent.value.msg_id,
            expires_at = time.now_ms() + math.floor(timeout_seconds * 1000),
        }
    elseif kind == "disconnect" then
        runtime.pending_disconnect_reply = {
            request_id = sent.value.msg_id,
            expires_at = time.now_ms() + math.floor(timeout_seconds * 1000),
        }
    end

    return result.ok(sent.value.msg_id)
end

---@param runtime table
local function request_gate_status(runtime)
    if runtime.pending_status ~= nil then
        return
    end

    local sent = send_request(runtime, "gate_controller", {
        action = "status",
    }, "gate_status", command_timeout.for_action("status"))
    if not sent.ok then
        runtime.last_gate_error = sent.error
    end
end

---@param runtime table
---@return boolean
local function should_request_gate_status(runtime)
    if suppress_background_status_poll(runtime) then
        return false
    end

    if runtime.pending_status ~= nil then
        return false
    end

    if runtime.last_gate_state_at == nil then
        return true
    end

    return time.now_ms() - runtime.last_gate_state_at >= STATE_FALLBACK_REQUEST_INTERVAL_MS
end

---@param runtime table
---@param line string
print_terminal_feedback = function(runtime, line)
    print(line)
    render_monitor(runtime)
end

---@param runtime table
---@return SgcResult
local function refresh_address_book(runtime)
    local refreshed = address_book_client.start(runtime.config)
    if refreshed.ok and refreshed.value.book ~= nil then
        runtime.book = refreshed.value.book
        runtime.destinations = visible_destinations(runtime.book, runtime.config.site)
        runtime.local_site = runtime.book.sites[runtime.config.site]
        runtime.home_page_index = 1
        set_flash_message(runtime, "Address book refreshed", 3000)
        return result.ok(true)
    end

    local refresh_error = refreshed.ok and refreshed.value.error or refreshed.error
    set_flash_message(runtime, "Refresh failed", 3000)
    return result.err(refresh_error or "refresh_failed")
end

---@param runtime table
---@param site_status SgcSiteStatus
local function maybe_refresh_from_site_status(runtime, site_status)
    if site_status.site ~= runtime.config.site or site_status.role ~= "site_controller" then
        return
    end

    if site_status.maintenance_mode == true then
        set_flash_message(runtime, "Site restarting", 3000)
        return
    end

    if site_status.address_book_available ~= true or type(site_status.address_book_revision) ~= "number" then
        return
    end

    local current_revision = type(runtime.book) == "table" and runtime.book.revision or nil
    if type(current_revision) == "number" and current_revision >= site_status.address_book_revision then
        return
    end

    local refreshed = refresh_address_book(runtime)
    if refreshed.ok then
        set_flash_message(runtime, "Address book updated", 3000)
    else
        set_flash_message(runtime, "Address book update failed", 3000)
    end
end

---@param runtime table
---@param reason string?
local function show_reboot_notice(runtime, reason)
    set_flash_message(runtime, "Site restarting", 3000)
    render_monitor(runtime)
    print("Site restarting" .. (reason ~= nil and ": " .. tostring(reason) or ""))
end

---@param runtime table
---@param logger table?
---@param line string
local function handle_input(runtime, logger, line)
    local input = trim(line)
    if input == "" then
        return
    end

    if input == "help" then
        ui_term.print_command_help(INTERACTIVE_TERMINAL_COMMAND_SPECS)
        render_monitor(runtime)
        return
    end

    if input == "refresh" then
        local refreshed = refresh_address_book(runtime)
        if refreshed.ok then
            print_terminal_feedback(runtime, "Address book refreshed")
        else
            print_terminal_feedback(runtime, "Refresh failed: " .. tostring(refreshed.error))
        end
        return
    end

    local requested_mode = input:match("^mode%s+([%w_%-]+)$")
    if requested_mode ~= nil then
        if constants.DIAL_MODE_SET[requested_mode] then
            runtime.selected_mode = requested_mode
            print_terminal_feedback(runtime, "Dial mode set to " .. requested_mode)
        else
            print_terminal_feedback(runtime, "Unsupported dial mode: " .. tostring(requested_mode))
        end
        return
    end

    if gate_is_incoming(runtime) or gate_is_outgoing(runtime) or runtime.pending_dial_reply ~= nil then
        print_terminal_feedback(runtime, "Gate is busy")
        return
    end

    local selected = resolve_destination_selection(runtime.book, input, runtime.config.site)
    if not selected.ok then
        print_terminal_feedback(runtime, "Unknown destination: " .. tostring(input))
        return
    end

    request_dial(runtime, selected.value, true)
end

---@param runtime table
---@param incoming table
local function handle_network_message(runtime, incoming)
    local lifecycle_handled = host_lifecycle.handle_command(runtime.config, incoming, nil, {
        before_reboot = function(intent)
            show_reboot_notice(runtime, intent.reason)
            return result.ok(true)
        end,
    })
    if not lifecycle_handled.ok then
        set_flash_message(runtime, "Lifecycle error: " .. tostring(lifecycle_handled.error), nil)
        return
    end

    if lifecycle_handled.ok and type(lifecycle_handled.value) == "table" and lifecycle_handled.value.handled == true then
        return
    end

    if incoming.protocol == constants.PROTOCOLS.state and incoming.envelope.type == "state" then
        if incoming.envelope.role == "site_controller" and incoming.envelope.site == runtime.config.site then
            local validated_site_status = site_message.validate_status_payload(incoming.envelope.payload)
            if validated_site_status.ok then
                maybe_refresh_from_site_status(runtime, validated_site_status.value.status)
            else
                set_flash_message(runtime, "Invalid site status payload", nil)
            end
            return
        end

        if incoming.envelope.role ~= "gate_controller" or incoming.envelope.site ~= runtime.config.site then
            return
        end

        local validated_state = gate_message.validate_state_payload(incoming.envelope.payload)
        if not validated_state.ok then
            set_flash_message(runtime, "Invalid gate state payload", nil)
            return
        end

        apply_gate_state_snapshot(runtime, validated_state.value.state, validated_state.value.sequence)
        return
    end

    if incoming.protocol ~= constants.PROTOCOLS.command or incoming.envelope.type ~= "result" then
        return
    end

    local pending = runtime.pending_requests[incoming.envelope.reply_to]
    if pending == nil then
        return
    end

    runtime.pending_requests[incoming.envelope.reply_to] = nil

    local validated = command_message.validate_result_payload(incoming.envelope.payload)
    if not validated.ok then
        set_flash_message(runtime, "Invalid reply payload", nil)
        return
    end

    local payload = validated.value
    if pending.kind == "gate_status" then
        clear_pending_status_request(runtime)
        if payload.ok == true and type(payload.result) == "table" and type(payload.result.state) == "table" then
            apply_gate_state_reply_snapshot(runtime, payload.result.state)
        else
            runtime.last_gate_error = payload.error
        end
        return
    end

    if pending.kind == "dial" then
        clear_pending_dial_request(runtime)
        runtime.pending_dial = nil
        if payload.ok == true and type(payload.result) == "table" then
            if type(payload.result.state) == "table" then
                apply_gate_state_reply_snapshot(runtime, payload.result.state)
            end
            runtime.last_dial_result = payload.result
            runtime.cancel_requested = false
        else
            runtime.last_dial_result = nil
            runtime.pending_dial = nil
            if
                runtime.cancel_requested == true
                and (payload.error == "dial_cancelled" or payload.error == "command_timeout")
            then
                complete_cancelled_dial(runtime)
            else
                runtime.outgoing_session = nil
                set_flash_message(runtime, "Dial failed: " .. tostring(payload.error), nil)
            end
        end
        return
    end

    if pending.kind == "disconnect" then
        clear_pending_disconnect_request(runtime)
        if payload.ok == true and type(payload.result) == "table" then
            if type(payload.result.state) == "table" then
                apply_gate_state_reply_snapshot(runtime, payload.result.state)
            end
            if runtime.cancel_requested == true
                and not gate_is_outgoing(runtime)
            then
                complete_cancelled_dial(runtime)
            end
        else
            if runtime.cancel_requested == true and payload.error == "command_timeout" then
                complete_cancelled_dial(runtime)
            else
                runtime.cancel_requested = false
                set_flash_message(runtime, "Disconnect failed: " .. tostring(payload.error), nil)
            end
        end
    end
end

---@param runtime table
---@param network_error SgcResult
local function handle_network_error(runtime, network_error)
    if network_error.error == "receive_timeout" or network_error.error == "unexpected_protocol" then
        return
    end

    set_flash_message(runtime, "Network error: " .. tostring(network_error.error), nil)
end

---@param runtime table
---@return string
local function prompt_text(runtime)
    return "[" .. runtime.selected_mode .. "] destination> "
end

---@param runtime table
local function print_terminal_intro(runtime)
    ui_term.console_header(INTERACTIVE_TERMINAL_COMMAND_SPECS, fallback_terminal_label(runtime.config))
    print("Enter destination number or exact name.")
    print("Monitor shows live gate status.")
    print("")
end

---@param runtime table
---@param logger table?
local function input_loop(runtime, logger)
    print_terminal_intro(runtime)
    while true do
        local input = read_line(prompt_text(runtime))
        if not input.ok then
            runtime.exit_result = input
            return
        end

        if trim(input.value) == "help" then
            ui_term.show_help_screen(INTERACTIVE_TERMINAL_COMMAND_SPECS, fallback_terminal_label(runtime.config))
            print_terminal_intro(runtime)
        elseif os ~= nil and type(os.queueEvent) == "function" then
            os.queueEvent(INPUT_EVENT, input.value)
        else
            handle_input(runtime, logger, input.value)
        end
    end
end

---@param runtime table
local function network_loop(runtime)
    while true do
        local received = transport.receive(runtime.config, NETWORK_RECEIVE_TIMEOUT_SECONDS, nil)
        if received.ok then
            os.queueEvent(NETWORK_EVENT, received.value)
        elseif received.error ~= "receive_timeout" and not transport.is_nonfatal_receive_error(received.error) then
            os.queueEvent(NETWORK_ERROR_EVENT, received)
        end
    end
end

---@param runtime table
---@param logger table?
local function controller_loop(runtime, logger)
    request_gate_status(runtime)
    render_monitor(runtime)

    local tick_timer = os.startTimer(UI_TICK_INTERVAL_SECONDS)
    while true do
        local event, first, second, third = os.pullEvent()
        if event == "timer" and first == tick_timer then
            if should_request_gate_status(runtime) then
                request_gate_status(runtime)
            end
            update_session_state(runtime)
            render_monitor(runtime)
            tick_timer = os.startTimer(UI_TICK_INTERVAL_SECONDS)
        elseif event == INPUT_EVENT then
            handle_input(runtime, logger, first)
            update_session_state(runtime)
            render_monitor(runtime)
        elseif event == NETWORK_EVENT then
            handle_network_message(runtime, first)
            update_session_state(runtime)
            render_monitor(runtime)
        elseif event == NETWORK_ERROR_EVENT then
            handle_network_error(runtime, first)
            update_session_state(runtime)
            render_monitor(runtime)
        elseif event == "monitor_touch" then
            handle_monitor_touch(runtime, first, second, third)
            update_session_state(runtime)
            render_monitor(runtime)
        end

        if runtime.exit_result ~= nil then
            return
        end
    end
end

---@param config table
---@param logger table?
---@return SgcResult
local function start_interactive(config, logger)
    local opened = transport.open(config.modems.site)
    if not opened.ok then
        return opened
    end

    local cached = address_book_client.start(config)
    if not cached.ok or cached.value.book == nil then
        return finish_without_crash(config, "Address Book Unavailable", {
            "Error: " .. tostring(cached.error),
        })
    end

    if cached.value.error ~= nil and cached.value.book == nil then
        return finish_without_crash(config, "Address Book Unavailable", {
            "Error: " .. tostring(cached.value.error),
        })
    end

    local runtime = {
        config = config,
        book = cached.value.book,
        local_site = cached.value.book.sites[config.site],
        destinations = visible_destinations(cached.value.book, config.site),
        selected_mode = constants.DEFAULT_DIAL_MODE,
        pending_requests = {},
        home_page_index = 1,
        pending_status = nil,
        pending_dial_reply = nil,
        pending_disconnect_reply = nil,
        pending_dial = nil,
        cancel_requested = false,
        outgoing_session = nil,
        outgoing_connected_at = nil,
        incoming_session = nil,
        incoming_connected_at = nil,
        gate_state = nil,
        last_gate_state_at = nil,
        last_gate_state_sequence = nil,
        last_gate_error = nil,
        last_dial_result = nil,
        flash_message = nil,
        monitor_id = nil,
        monitor_touch_targets = nil,
        monitor_session = nil,
        cancelled_session = nil,
        cancelled_until = nil,
        exit_result = nil,
    }

    local announced = discovery.announce(config, {
        services = { config.role },
    })
    if not announced.ok and logger ~= nil and type(logger.warn) == "function" then
        logger:warn("failed to broadcast hello", announced.details)
    end

    parallel.waitForAny(
        function()
            controller_loop(runtime, logger)
        end,
        function()
            network_loop(runtime)
        end,
        function()
            input_loop(runtime, logger)
        end
    )

    return runtime.exit_result or result.err("dial_console_stopped")
end

---@param config table
---@param logger table?
---@return SgcResult
function dial_console.start(config, logger)
    if parallel == nil
        or type(parallel.waitForAny) ~= "function"
        or os == nil
        or type(os.pullEvent) ~= "function"
        or type(os.queueEvent) ~= "function"
    then
        return result.err("unsupported_environment", {
            requires = {
                "parallel.waitForAny",
                "os.pullEvent",
                "os.queueEvent",
            },
        })
    end

    return start_interactive(config, logger)
end

return dial_console
