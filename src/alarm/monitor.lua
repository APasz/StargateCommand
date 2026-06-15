local alarm_output = require("alarm.output")
local alarm_speaker = require("alarm.speaker")
local constants = require("core.constants")
local result = require("core.result")
local time = require("core.time")
local ui_monitor = require("ui.monitor")

local alarm_monitor = {}
local HEADER_LINES = 2
local FOOTER_LINES = 1
local GRID_GAP = 1
local MIN_TILE_WIDTH = 7
local MIN_TILE_HEIGHT = 3
local TARGET_TILE_ASPECT = 2
local STATUS_TTL_MS = 5000
local SIGNAL_LABELS = {
    connection_established = "connected",
    connection_incoming = "incoming",
    connection_outgoing = "outgoing",
    dialing = "dialing",
    connection_disconnected = "disconnect",
    traveller_in = "traveller in",
    traveller_out = "traveller out",
    wormhole_incoming = "wormhole in",
    wormhole_outgoing = "wormhole out",
    chevron_engaged = "chevron",
    message_received = "message",
    reset = "reset",
    system_error = "system error",
}
local SIDE_LABELS = {
    left = "left",
    right = "right",
    top = "top",
    bottom = "bottom",
    front = "front",
    back = "rear",
}

---@return table
function alarm_monitor.new_state()
    return {
        monitor_id = nil,
        monitor_side = nil,
        tiles = {},
        status_text = nil,
        status_until = 0,
    }
end

---@param state table
---@param text string
---@param now_ms integer?
---@param ttl_ms integer?
function alarm_monitor.note(state, text, now_ms, ttl_ms)
    if type(state) ~= "table" then
        return
    end

    state.status_text = tostring(text or "")
    state.status_until = (now_ms or time.now_ms()) + (ttl_ms or STATUS_TTL_MS)
end

---@param color_name string?
---@return integer?
local function color_value(color_name)
    if type(colors) ~= "table" or type(color_name) ~= "string" then
        return nil
    end

    local value = colors[color_name]
    if type(value) == "number" then
        return value
    end

    return nil
end

---@param signal_name string
---@return string
local function display_label(signal_name)
    return SIGNAL_LABELS[signal_name] or tostring(signal_name or "?"):gsub("_", " ")
end

---@param side string
---@return string
local function side_label(side)
    return SIDE_LABELS[side] or tostring(side or "?"):sub(1, 1):upper()
end

---@param text string
---@param width integer
---@param max_lines integer
---@return string[]
local function wrap_label(text, width, max_lines)
    if width <= 0 or max_lines <= 0 then
        return {}
    end

    local words = {}
    for word in tostring(text or ""):gmatch("%S+") do
        words[#words + 1] = word
    end

    if #words == 0 then
        return { "" }
    end

    local lines = {}
    local current = words[1]
    for index = 2, #words do
        local candidate = current .. " " .. words[index]
        if #candidate <= width then
            current = candidate
        else
            lines[#lines + 1] = ui_monitor.fit_line(current, width)
            current = words[index]
            if #lines >= max_lines - 1 then
                break
            end
        end
    end

    if #lines < max_lines then
        lines[#lines + 1] = ui_monitor.fit_line(current, width)
    end

    if #lines > max_lines then
        while #lines > max_lines do
            table.remove(lines)
        end
    end

    return lines
end

---@param count integer
---@param divisor integer
---@return integer
local function ceil_div(count, divisor)
    return math.floor((count + divisor - 1) / divisor)
end

---@param width integer
---@param height integer
---@param count integer
---@param top_lines integer
---@return table?
local function choose_grid(width, height, count, top_lines)
    if count <= 0 then
        return nil
    end

    local grid_height = height - top_lines - FOOTER_LINES
    if width < MIN_TILE_WIDTH or grid_height < MIN_TILE_HEIGHT then
        return nil
    end

    local best = nil
    for columns = 1, count do
        local rows = ceil_div(count, columns)
        local tile_width = math.floor((width - (columns - 1) * GRID_GAP) / columns)
        local tile_height = math.floor((grid_height - (rows - 1) * GRID_GAP) / rows)
        if tile_width >= MIN_TILE_WIDTH and tile_height >= MIN_TILE_HEIGHT then
            local candidate = {
                columns = columns,
                rows = rows,
                tile_width = tile_width,
                tile_height = tile_height,
                aspect = tile_width / tile_height,
                aspect_distance = math.abs(tile_width / tile_height - TARGET_TILE_ASPECT),
            }
            if best == nil
                or (candidate.tile_width > candidate.tile_height and best.tile_width <= best.tile_height)
                or (
                    (candidate.tile_width > candidate.tile_height) == (best.tile_width > best.tile_height)
                    and candidate.aspect_distance < best.aspect_distance
                )
                or (
                    (candidate.tile_width > candidate.tile_height) == (best.tile_width > best.tile_height)
                    and candidate.aspect_distance == best.aspect_distance
                    and candidate.tile_width * candidate.tile_height > best.tile_width * best.tile_height
                )
                or (
                    (candidate.tile_width > candidate.tile_height) == (best.tile_width > best.tile_height)
                    and candidate.aspect_distance == best.aspect_distance
                    and candidate.tile_width * candidate.tile_height == best.tile_width * best.tile_height
                    and candidate.rows < best.rows
                )
            then
                best = candidate
            end
        end
    end

    return best
end

---@param snapshot table
---@return integer
local function active_output_count(snapshot)
    local active = 0
    for _, entry in ipairs(snapshot) do
        if entry.active == true then
            active = active + 1
        end
    end

    return active
end

---@param runtime table
---@return string
local function top_status(runtime)
    if runtime.last_gate_fault ~= nil and runtime.last_site_fault ~= nil then
        return "gate " .. tostring(runtime.last_gate_fault) .. "  site " .. tostring(runtime.last_site_fault)
    end

    if runtime.last_gate_fault ~= nil then
        return "gate fault " .. tostring(runtime.last_gate_fault)
    end

    if runtime.last_site_fault ~= nil then
        return "site fault " .. tostring(runtime.last_site_fault)
    end

    local gate_state = runtime.last_gate_state
    if type(gate_state) == "table" and gate_state.connected == true then
        return "connected " .. tostring(gate_state.connection_direction or "unknown")
    end

    if type(runtime.signals) == "table" and runtime.signals.dialing == true then
        return "dialing"
    end

    if type(gate_state) == "table" and gate_state.open == true then
        return "wormhole open"
    end

    return "idle"
end

---@param runtime table
---@param entries table[]
---@param now_ms integer
---@return string
local function status_line(runtime, entries, now_ms)
    if runtime.monitor.status_text ~= nil and runtime.monitor.status_until > now_ms then
        return runtime.monitor.status_text
    end

    if runtime.last_gate_fault ~= nil or runtime.last_site_fault ~= nil then
        return top_status(runtime)
    end

    return string.format("%d/%d outputs active", active_output_count(entries), #entries)
end

---@param runtime table
---@param now_ms integer
---@return string[]
local function header_lines(runtime, now_ms)
    return {
        string.format("SGC Alarm %s  %s", tostring(runtime.config.site), time.now_hms()),
        top_status(runtime),
    }
end

---@param runtime table
---@return integer
local function reserved_top_lines(runtime)
    return HEADER_LINES
end

---@param entry table
---@return integer?
local function border_color(entry)
    if entry.driver == "bundled" then
        return color_value(entry.wire_color)
    end

    if type(colors) ~= "table" then
        return nil
    end

    if entry.active == true then
        return type(colors.black) == "number" and colors.black or colors.white
    end

    return type(colors.white) == "number" and colors.white or nil
end

---@param entry table
---@return boolean
local function has_full_border(entry)
    return entry.driver == "bundled"
end

---@param entry table
---@return string
local function tile_title(entry)
    if entry.driver == "speaker" then
        return tostring(entry.pattern or "speaker")
    end

    return side_label(entry.side)
end

---@param entry table
---@return string
local function tile_source(entry)
    if entry.driver == "bundled" then
        return tostring(entry.wire_color)
    end

    if entry.driver == "speaker" then
        return tostring(entry.pattern or "speaker")
    end

    return tostring(entry.side)
end

---@param entry table
---@return integer?
local function fill_color(entry)
    if type(colors) ~= "table" then
        return nil
    end

    if entry.active == true then
        return type(colors.white) == "number" and colors.white or nil
    end

    return type(colors.black) == "number" and colors.black or nil
end

---@param entry table
---@return integer?
local function text_color(entry)
    if type(colors) ~= "table" then
        return nil
    end

    if entry.active == true then
        return type(colors.black) == "number" and colors.black or colors.white
    end

    return type(colors.white) == "number" and colors.white or nil
end

---@param runtime table
---@param now_ms integer
---@return SgcResult
local function snapshot_entries(runtime, now_ms)
    local output_entries = alarm_output.snapshot(runtime.alarm.outputs, runtime.signals or {}, runtime.output_state, now_ms)
    if not output_entries.ok then
        return output_entries
    end

    local bindings = type(runtime.alarm) == "table"
        and type(runtime.alarm.speaker) == "table"
        and type(runtime.alarm.speaker.bindings) == "table"
        and runtime.alarm.speaker.bindings
        or {}
    local speaker_entries = alarm_speaker.snapshot(runtime.speaker, bindings, runtime.signals or {})
    local entries = {}
    for _, entry in ipairs(output_entries.value) do
        entries[#entries + 1] = entry
    end
    for _, entry in ipairs(speaker_entries) do
        entries[#entries + 1] = entry
    end

    return result.ok(entries)
end

---@param surface table
---@param x integer
---@param y integer
---@param width integer
---@param height integer
---@param background integer?
---@param border integer?
---@param full boolean
local function draw_panel(surface, x, y, width, height, background, border, full)
    surface:fill_rect(x, y, width, height, background)
    if type(border) ~= "number" or width < 2 or height < 2 then
        return
    end

    if full then
        surface:frame_rect(x, y, width, height, border)
        return
    end

    surface:fill_rect(x, y, 1, height, border)
    surface:fill_rect(x + width - 1, y, 1, height, border)
end

---@param surface table
---@param x integer
---@param y integer
---@param width integer
---@param height integer
---@param entry table
local function draw_tile(surface, x, y, width, height, entry)
    local border = border_color(entry)
    local background = fill_color(entry)
    local full_border = has_full_border(entry)
    draw_panel(surface, x, y, width, height, background, border, full_border)

    local foreground = text_color(entry)
    local inner_x = x + 1
    local inner_y = y + 1
    local inner_width = width - 2
    local inner_height = height - 2

    if full_border and border ~= nil then
        surface:write_at(x + 2, y, tile_title(entry), {
            width = math.max(1, width - 3),
            align = "left",
            background = border,
            foreground = type(colors) == "table" and colors.black or foreground,
        })
    else
        surface:write_at(x + 2, y, tile_title(entry), {
            width = math.max(1, width - 3),
            align = "left",
            background = background,
            foreground = foreground,
        })
    end

    local label_lines = wrap_label(display_label(entry.signal), inner_width, math.max(1, math.min(2, inner_height)))
    local start_y = inner_y + math.floor((inner_height - #label_lines) / 2)
    for index, line in ipairs(label_lines) do
        surface:write_at(inner_x, start_y + index - 1, line, {
            width = inner_width,
            align = "center",
            background = background,
            foreground = foreground,
        })
    end
end

---@param surface table
---@param runtime table
---@param entries table[]
---@param top_lines integer
local function draw_grid(surface, runtime, entries, top_lines)
    local width = surface.width or 0
    local height = surface.height or 0
    local grid = choose_grid(width, height, #entries, top_lines)
    runtime.monitor.tiles = {}

    if grid == nil then
        local row = top_lines + 1
        for _, entry in ipairs(entries) do
            if row >= height then
                break
            end

            surface:write_line(row, string.format(
                "%s %s %s",
                entry.active == true and "*" or "-",
                tile_source(entry),
                display_label(entry.signal)
            ))
            row = row + 1
        end
        return
    end

    local start_y = top_lines + 1
    for index, entry in ipairs(entries) do
        local column = (index - 1) % grid.columns
        local row = math.floor((index - 1) / grid.columns)
        local x = 1 + column * (grid.tile_width + GRID_GAP)
        local y = start_y + row * (grid.tile_height + GRID_GAP)
        draw_tile(surface, x, y, grid.tile_width, grid.tile_height, entry)
        runtime.monitor.tiles[#runtime.monitor.tiles + 1] = {
            x = x,
            y = y,
            width = grid.tile_width,
            height = grid.tile_height,
            entry = entry,
        }
    end
end

---@param runtime table
---@param now_ms integer
---@return SgcResult
function alarm_monitor.render(runtime, now_ms)
    if type(runtime.monitor) ~= "table" then
        runtime.monitor = alarm_monitor.new_state()
    end

    local monitor_side = runtime.config.modems ~= nil and runtime.config.modems.peripheral or nil
    if monitor_side == nil then
        return result.ok(false)
    end

    local opened = ui_monitor.open(monitor_side, {
        text_scale = runtime.alarm.monitor_text_scale,
    })
    if not opened.ok then
        return opened
    end

    local surface = opened.value
    runtime.monitor.monitor_side = monitor_side
    runtime.monitor.monitor_id = surface.id

    local snapshot = snapshot_entries(runtime, now_ms)
    if not snapshot.ok then
        return snapshot
    end

    if type(colors) == "table" and type(colors.black) == "number" then
        surface:clear(colors.black)
    else
        surface:clear()
    end

    local headers = header_lines(runtime, now_ms)
    local top_lines = reserved_top_lines(runtime)
    surface:write_line(1, headers[1], {
        foreground = type(colors) == "table" and colors.white or nil,
        background = type(colors) == "table" and colors.black or nil,
    })
    surface:write_line(2, headers[2], {
        foreground = type(colors) == "table" and colors.white or nil,
        background = type(colors) == "table" and colors.black or nil,
    })

    draw_grid(surface, runtime, snapshot.value, top_lines)
    surface:write_line(surface.height or (HEADER_LINES + #snapshot.value + FOOTER_LINES), status_line(runtime, snapshot.value, now_ms), {
        foreground = type(colors) == "table" and colors.white or nil,
        background = type(colors) == "table" and colors.black or nil,
    })

    return result.ok(true)
end

---@param entry table
---@return string
local function touch_status(entry)
    local wire = entry.driver == "bundled" and tostring(entry.wire_color) or "bare"
    local mode = entry.mode == "pulse" and "pulse" or "steady"
    local state = entry.active == true and "on" or "off"
    local override = type(entry.override_active) == "boolean" and " manual" or ""
    return string.format("%s %s %s %s%s", tostring(wire), mode, display_label(entry.signal), state, override)
end

---@param runtime table
---@param target string
---@param x integer
---@param y integer
---@param now_ms integer
---@return table?
function alarm_monitor.handle_touch(runtime, target, x, y, _now_ms)
    if type(runtime.monitor) ~= "table" then
        return nil
    end

    if target ~= runtime.monitor.monitor_side and target ~= runtime.monitor.monitor_id then
        return nil
    end

    for _, tile in ipairs(runtime.monitor.tiles or {}) do
        if x >= tile.x and x < tile.x + tile.width and y >= tile.y and y < tile.y + tile.height then
            return tile.entry
        end
    end

    return nil
end

return alarm_monitor
