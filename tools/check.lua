package.path = "src/?.lua;src/?/init.lua;" .. package.path

local address_book = require("address_book")
local address_book_client = require("address_book.client")
local address_book_message = require("address_book.message")
local address_book_network = require("address_book.network")
local address_book_server = require("address_book.server")
local command_message = require("command.message")
local command_network = require("command.network")
local command_schema = require("command.schema")
local command_timeout = require("command.timeout")
local config_defaults = require("config.default")
local config_schema = require("config.schema")
local constants = require("core.constants")
local envelope = require("net.envelope")
local gate_command = require("gate.command")
local gate_controller = require("gate.controller")
local gate_interface = require("gate.interface")
local gate_message = require("gate.message")
local gate_state = require("gate.state")
local alarm_monitor = require("alarm.monitor")
local alarm_console = require("alarm.console")
local alarm_output = require("alarm.output")
local alarm_signal = require("alarm.signal")
local alarm_speaker = require("alarm.speaker")
local net_inbox = require("net.inbox")
local alarm_controller = require("services.alarm_controller")
local dial_console = require("services.dial_console")
local rednet_transport = require("net.rednet_transport")
local result = require("core.result")
local sample = require("address_book.sample")
local site_command = require("site.command")
local site_controller = require("site.controller")
local site_message = require("site.message")
local startup = require("startup")
local tablex = require("core.tablex")
local ui_monitor = require("ui.monitor")
local update_planner = require("update.planner")
local update_schema = require("update.schema")

local function list_lua_files()
    local handle = io.popen(
        "find . -type f -name '*.lua' -not -path './.git/*' -not -path './.agents/*' -not -path './.codex/*'"
    )
    if handle == nil then
        return nil, "io.popen unavailable"
    end

    local files = {}
    for line in handle:lines() do
        files[#files + 1] = line
    end
    handle:close()
    table.sort(files)
    return files, nil
end

local function syntax_check(files)
    local failures = {}

    for _, path in ipairs(files) do
        local chunk, load_error = loadfile(path)
        if chunk == nil then
            failures[#failures + 1] = {
                path = path,
                error = load_error,
            }
        end
    end

    return failures
end

local function print_failures(failures)
    for _, failure in ipairs(failures) do
        io.stderr:write(string.format("FAIL %s: %s\n", failure.path, failure.error))
    end
end

local files, list_error = list_lua_files()
if files == nil then
    io.stderr:write("Unable to enumerate Lua files: " .. tostring(list_error) .. "\n")
    os.exit(1)
end

local syntax_failures = syntax_check(files)
if #syntax_failures > 0 then
    print_failures(syntax_failures)
    os.exit(1)
end

local validation = address_book.validate(sample.create())
if not validation.ok then
    io.stderr:write("Sample address book validation failed\n")
    os.exit(1)
end

local function check_section_1()
do
    local lifecycle_request = require("lifecycle.message").validate_site_request_payload(
        require("lifecycle.message").build_site_request_payload("command", {
            action = "reboot_hosts",
            scope = "role",
            target_role = "gate_controller",
            request_id = "lifecycle-check",
            reason = "update",
        })
    )
    if not lifecycle_request.ok then
        io.stderr:write("Lifecycle site request validation failed\n")
        os.exit(1)
    end

    local host_request = require("lifecycle.message").validate_host_request_payload(
        require("lifecycle.message").build_host_request_payload("command", "gate_controller", {
            action = "reboot_host",
            request_id = "host-check",
            reason = "cache",
            requested_by_role = "site_controller",
            requested_by_site = "command",
        })
    )
    if not host_request.ok then
        io.stderr:write("Lifecycle host request validation failed\n")
        os.exit(1)
    end
end
end
check_section_1()

local function check_section_2()
do
    local default_address_book_config = config_defaults.for_role("address_book")
    if default_address_book_config.address_book.mode ~= "server"
        or default_address_book_config.address_book.server_path ~= constants.DEFAULT_ADDRESS_BOOK_SERVER_PATH
        or default_address_book_config.address_book.bootstrap_on_missing ~= true
    then
        io.stderr:write("Address book role defaults are inconsistent\n")
        os.exit(1)
    end
end
end
check_section_2()

local function check_section_3()
do
    local added_site = tablex.deep_copy(validation.value.sites.nether)
    added_site.id = "pegasus_alpha"
    added_site.name = "Pegasus Alpha"
    added_site.location.galaxy = "pegasus"
    added_site.visibility.hidden_at = { "future_outpost" }
    added_site.visibility.visible_from = { "future_outpost", "*" }
    added_site.visibility.intergalactic = { "future_outpost" }

    local updated_book = address_book.add_site(validation.value, added_site, "tester", 123456)
    if not updated_book.ok
        or updated_book.value.revision ~= validation.value.revision + 1
        or updated_book.value.updated_by ~= "tester"
        or updated_book.value.updated_at ~= 123456
        or updated_book.value.sites.pegasus_alpha == nil
        or updated_book.value.sites.pegasus_alpha.visibility.hidden_at[1] ~= "future_outpost"
    then
        io.stderr:write("Address book add-site mutation failed\n")
        os.exit(1)
    end

    added_site.name = "Pegasus Alpha Prime"
    local edited_book = address_book.update_site(updated_book.value, added_site, "tester-2", 123457)
    if not edited_book.ok
        or edited_book.value.revision ~= updated_book.value.revision + 1
        or edited_book.value.updated_by ~= "tester-2"
        or edited_book.value.updated_at ~= 123457
        or edited_book.value.sites.pegasus_alpha == nil
        or edited_book.value.sites.pegasus_alpha.name ~= "Pegasus Alpha Prime"
    then
        io.stderr:write("Address book update-site mutation failed\n")
        os.exit(1)
    end

    local removed_book = address_book.remove_site(edited_book.value, "pegasus_alpha", "tester-3", 123458)
    if not removed_book.ok
        or removed_book.value.revision ~= edited_book.value.revision + 1
        or removed_book.value.updated_by ~= "tester-3"
        or removed_book.value.updated_at ~= 123458
        or removed_book.value.sites.pegasus_alpha ~= nil
    then
        io.stderr:write("Address book remove-site mutation failed\n")
        os.exit(1)
    end
end

local alarm_config_validation = config_schema.validate(config_defaults.for_role("alarm_controller", {
    alarm = {
        poll_interval_ms = 100,
        trigger_on_fault = true,
        outputs = {
            {
                driver = "redstone",
                side = "back",
                signal = "connection_established",
                active_high = false,
            },
            {
                driver = "bundled",
                side = "left",
                channels = {
                    magenta = {
                        signal = "system_error",
                        mode = "pulse",
                    },
                    orange = "connection_established",
                },
            },
        },
    },
}))
if not alarm_config_validation.ok then
    io.stderr:write("Alarm config validation failed\n")
    os.exit(1)
end

local default_alarm_config = config_defaults.for_role("alarm_controller")
if default_alarm_config.alarm.outputs[1].driver ~= "redstone"
    or default_alarm_config.alarm.outputs[1].side ~= "left"
    or default_alarm_config.alarm.outputs[1].signal ~= "connection_established"
    or default_alarm_config.alarm.outputs[2].driver ~= "redstone"
    or default_alarm_config.alarm.outputs[2].side ~= "right"
    or default_alarm_config.alarm.outputs[2].signal ~= "system_error"
    or default_alarm_config.alarm.outputs[3].driver ~= "bundled"
    or default_alarm_config.alarm.outputs[3].side ~= "back"
    or default_alarm_config.alarm.outputs[3].channels.orange ~= "connection_established"
    or default_alarm_config.alarm.outputs[3].channels.magenta.signal ~= "system_error"
    or default_alarm_config.alarm.outputs[3].channels.magenta.mode ~= "pulse"
    or default_alarm_config.alarm.outputs[3].channels.blue ~= "wormhole_incoming"
    or default_alarm_config.alarm.outputs[3].channels.green ~= "chevron_engaged"
    or default_alarm_config.alarm.outputs[3].channels.red ~= "wormhole_outgoing"
    or default_alarm_config.alarm.outputs[3].channels.lightBlue ~= "traveller_in"
    or default_alarm_config.alarm.outputs[3].channels.brown ~= "traveller_out"
    or default_alarm_config.alarm.outputs[3].channels.gray ~= "reset"
then
    io.stderr:write("Alarm default outputs layout failed\n")
    os.exit(1)
end

if default_alarm_config.alarm.speaker.bindings[1].signal ~= "system_error"
    or default_alarm_config.alarm.speaker.bindings[1].pattern ~= "pattern_beta"
    or default_alarm_config.alarm.speaker.bindings[2].signal ~= "connection_incoming"
    or default_alarm_config.alarm.speaker.bindings[2].pattern ~= "pattern_alpha"
then
    io.stderr:write("Alarm default speaker bindings failed\n")
    os.exit(1)
end

local edited_alarm_config = alarm_console.apply_alarm_config(default_alarm_config, {
    poll_interval_ms = 500,
    monitor_text_scale = 0.75,
    trigger_on_fault = false,
    output_side = "left",
    active_high = false,
    outputs = {
        {
            driver = "redstone",
            side = "back",
            signal = {
                signal = "system_error",
                mode = "pulse",
            },
            active_high = false,
        },
    },
    speaker = {
        bindings = {
            {
                signal = "connection_incoming",
                pattern = "pattern_alpha",
            },
        },
    },
})
local edited_alarm_validation = alarm_console.validate_config(edited_alarm_config)
if not edited_alarm_validation.ok
    or edited_alarm_config.alarm.output_side ~= nil
    or edited_alarm_config.alarm.active_high ~= nil
    or edited_alarm_config.alarm.outputs[1].signal.signal ~= "system_error"
then
    io.stderr:write("Alarm config editor apply validation failed\n")
    os.exit(1)
end

do
    local original_fs_config_editor = fs
    local original_textutils_config_editor = textutils
    local made_dir = nil
    local saved_config_payload = {}
    fs = {
        exists = function(path)
            return path ~= "sgc"
        end,
        makeDir = function(path)
            made_dir = path
        end,
        open = function(path, mode)
            if path ~= "sgc/config.lua" or mode ~= "w" then
                return nil
            end

            return {
                write = function(chunk)
                    saved_config_payload[#saved_config_payload + 1] = chunk
                end,
                close = function()
                end,
            }
        end,
    }
    textutils = {
        serialize = function(value, _options)
            return "serialized:" .. tostring(value.role)
        end,
    }

    local saved_alarm_config = alarm_console.save_config("sgc/config.lua", edited_alarm_config)
    fs = original_fs_config_editor
    textutils = original_textutils_config_editor

    if not saved_alarm_config.ok
        or made_dir ~= "sgc"
        or table.concat(saved_config_payload) ~= "return serialized:alarm_controller\n"
    then
        io.stderr:write("Alarm config editor save failed\n")
        os.exit(1)
    end
end

local default_dial_console_config = config_defaults.for_role("dial_console")
if default_dial_console_config.dial_console == nil
    or default_dial_console_config.dial_console.monitor_text_scale ~= constants.DEFAULT_MONITOR_TEXT_SCALE
then
    io.stderr:write("Dial console default monitor text scale failed\n")
    os.exit(1)
end

if default_alarm_config.alarm.monitor_text_scale ~= constants.DEFAULT_ALARM_MONITOR_TEXT_SCALE then
    io.stderr:write("Alarm default monitor text scale failed\n")
    os.exit(1)
end
end
check_section_3()

local function check_section_4()
do
    local status_payload = site_message.validate_status_payload(site_message.build_status_payload({
        site = "command",
        role = "site_controller",
        healthy = true,
        warnings_count = 0,
        address_book_available = true,
        address_book_revision = 1,
        maintenance_mode = true,
        maintenance_reason = "update",
        maintenance_action = "reboot_hosts",
    }, 1, 123456))
    if not status_payload.ok then
        io.stderr:write("Site maintenance status validation failed\n")
        os.exit(1)
    end
end

local invalid_dial_console_config = config_schema.validate(config_defaults.for_role("dial_console", {
    dial_console = {
        monitor_text_scale = 0,
    },
}))
if invalid_dial_console_config.ok then
    io.stderr:write("Dial console config validation unexpectedly accepted invalid monitor text scale\n")
    os.exit(1)
end

local invalid_alarm_monitor_config = config_schema.validate(config_defaults.for_role("alarm_controller", {
    alarm = {
        monitor_text_scale = 0,
    },
}))
if invalid_alarm_monitor_config.ok then
    io.stderr:write("Alarm config validation unexpectedly accepted invalid monitor text scale\n")
    os.exit(1)
end

local invalid_mixed_alarm_config = config_schema.validate(config_defaults.for_role("alarm_controller", {
    alarm = {
        outputs = {
            {
                driver = "redstone",
                side = "back",
                signal = "connection_established",
                active_high = true,
            },
            {
                driver = "bundled",
                side = "back",
                channels = {
                    red = "system_error",
                },
            },
        },
    },
}))
if invalid_mixed_alarm_config.ok then
    io.stderr:write("Alarm config validation unexpectedly accepted mixed outputs on one side\n")
    os.exit(1)
end

local invalid_reserved_alarm_color_config = config_schema.validate(config_defaults.for_role("alarm_controller", {
    alarm = {
        outputs = {
            {
                driver = "bundled",
                side = "left",
                channels = {
                    white = "system_error",
                },
            },
        },
    },
}))
if invalid_reserved_alarm_color_config.ok then
    io.stderr:write("Alarm config validation unexpectedly accepted reserved bundled output color\n")
    os.exit(1)
end

local function check_gate_state_payload_handling()
    local sample_gate_state = {
        side = "left",
        interface_type = "advanced_crystal_interface",
        connected = false,
        open = false,
        dialing_out = true,
        activity = "dialing_out",
        connection_direction = "outgoing",
        idle = false,
        partial_dial = true,
        local_address = { 1, 2, 3, 4, 5, 6 },
        dialed_address = { 1, 2, 3, 4, 5, 6, 0 },
        connected_address = nil,
        chevrons_engaged = 3,
        stargate_generation = 2,
        current_symbol = 9,
        energy = {
            stored = 100,
            capacity = 1000,
            available = true,
        },
        iris = {
            supported = true,
            identifier = "iris_a",
            installed = true,
            progress = 0,
            progress_percent = 0,
        },
    }
    local gate_state_payload = gate_message.build_state_payload(sample_gate_state, 7, 123456)
    local validated_gate_state_payload = gate_message.validate_state_payload(gate_state_payload)
    local changed_gate_state = tablex.deep_copy(sample_gate_state)
    changed_gate_state.chevrons_engaged = 4
    local site_runtime = {
        gate_contact = {
            last_success_at = nil,
            last_state = nil,
            last_state_sequence = nil,
        },
    }
    local handled_gate_state = site_controller.handle_gate_state_update({
        site = "command",
    }, site_runtime, {
        protocol = constants.PROTOCOLS.state,
        envelope = {
            type = "state",
            role = "gate_controller",
            site = "command",
            payload = gate_state_payload,
        },
    })
    local stale_gate_state_payload = gate_message.build_state_payload(changed_gate_state, 6, 123455)
    local handled_stale_gate_state = site_controller.handle_gate_state_update({
        site = "command",
    }, site_runtime, {
        protocol = constants.PROTOCOLS.state,
        envelope = {
            type = "state",
            role = "gate_controller",
            site = "command",
            payload = stale_gate_state_payload,
        },
    })
    if not validated_gate_state_payload.ok
        or not gate_state.same(sample_gate_state, validated_gate_state_payload.value.state)
        or gate_state.same(sample_gate_state, changed_gate_state)
        or gate_message.validate_state_payload({
            kind = "gate_state",
            sequence = 1,
            emitted_at = 1,
            state = {},
        }).ok
        or not handled_gate_state.ok
        or handled_gate_state.value.handled ~= true
        or not handled_stale_gate_state.ok
        or handled_stale_gate_state.value.handled ~= true
        or site_runtime.gate_contact.last_state == nil
        or site_runtime.gate_contact.last_state.chevrons_engaged ~= 3
        or site_runtime.gate_contact.last_state_sequence ~= 7
    then
        io.stderr:write("Gate state payload handling failed\n")
        os.exit(1)
    end
end

check_gate_state_payload_handling()

local function check_site_status_payload_handling()
    local sample_site_status = {
        site = "command",
        role = "site_controller",
        healthy = true,
        warnings_count = 0,
        address_book_available = true,
        address_book_error = nil,
        address_book_revision = 2,
        last_internal_error = nil,
        started_at = 12345,
    }
    local site_status_payload = site_message.build_status_payload(sample_site_status, 2, 654321)
    local validated_site_status_payload = site_message.validate_status_payload(site_status_payload)
    if not validated_site_status_payload.ok
        or validated_site_status_payload.value.status.site ~= "command"
        or site_message.validate_status_payload({
            kind = "site_status",
            sequence = 1,
            emitted_at = 1,
            status = {},
        }).ok
    then
        io.stderr:write("Site status payload handling failed\n")
        os.exit(1)
    end
end

check_site_status_payload_handling()

local original_settings = settings
local original_os = os
local original_startup_load_local_config = startup.load_local_config
local original_update_preflight = require("services.update_client").preflight
local original_main_run = require("main").run
local motd_value = nil
local settings_saved = false
local startup_label = nil
settings = {
    set = function(key, value)
        if key == "motd.enable" then
            motd_value = value
        end
    end,
    save = function()
        settings_saved = true
        return true
    end,
}
os = setmetatable({
    setComputerLabel = function(label)
        startup_label = label
    end,
}, {
    __index = original_os,
})
startup.load_local_config = function()
    return {
        site = "command",
        role = "site_controller",
        logging = {
            level = "info",
        },
    }, "/config.lua", nil
end
require("services.update_client").preflight = function(_config, _logger)
    return result.ok({
        applied = false,
    })
end
require("main").run = function(_config)
    return result.ok(true)
end

local startup_run_result = startup.run()

settings = original_settings
os = original_os
startup.load_local_config = original_startup_load_local_config
require("services.update_client").preflight = original_update_preflight
require("main").run = original_main_run

if startup_run_result ~= true
    or motd_value ~= false
    or settings_saved ~= true
    or startup_label ~= "command.site_controller"
then
    io.stderr:write("Startup did not disable motd automatically or sync the computer label\n")
    os.exit(1)
end
end
check_section_4()

local function check_section_5()
do
    local original_fs_startup = fs
    local original_dofile_startup = dofile
    local legacy_alarm_config = config_defaults.for_role("alarm_controller")
    legacy_alarm_config.alarm.outputs = nil
    legacy_alarm_config.alarm.speaker = nil
    legacy_alarm_config.alarm.output_side = "back"
    legacy_alarm_config.alarm.active_high = true

    fs = {
        exists = function(path)
            return path == "/config.lua"
        end,
    }
    dofile = function(path)
        if path ~= "/config.lua" then
            error("unexpected config path " .. tostring(path))
        end

        return legacy_alarm_config
    end

    local normalized_loaded_config, normalized_loaded_path, normalized_load_error = startup.load_local_config({
        "/config.lua",
    })

    fs = original_fs_startup
    dofile = original_dofile_startup

    if normalized_load_error ~= nil
        or normalized_loaded_path ~= "/config.lua"
        or normalized_loaded_config == nil
        or type(normalized_loaded_config.alarm.outputs) ~= "table"
        or normalized_loaded_config.alarm.outputs[2] == nil
        or normalized_loaded_config.alarm.outputs[2].signal ~= "system_error"
        or normalized_loaded_config.alarm.outputs[3] == nil
        or normalized_loaded_config.alarm.outputs[3].channels.magenta == nil
        or normalized_loaded_config.alarm.speaker == nil
        or normalized_loaded_config.alarm.speaker.bindings[1] == nil
        or normalized_loaded_config.alarm.speaker.bindings[1].signal ~= "system_error"
    then
        io.stderr:write("Startup config normalization failed\n")
        os.exit(1)
    end
end
end
check_section_5()

local visible_destinations = address_book.list_visible_destinations(validation.value, "command")
local sample_destination_site = visible_destinations[1] ~= nil and visible_destinations[1].id or nil
if sample_destination_site == nil then
    io.stderr:write("Sample address book has no visible destinations for command\n")
    os.exit(1)
end

if not address_book.can_see(validation.value, "command", sample_destination_site) then
    io.stderr:write("Visibility check failed for command -> " .. tostring(sample_destination_site) .. "\n")
    os.exit(1)
end

if address_book.get_best_address(validation.value, "command", sample_destination_site) == nil then
    io.stderr:write("Address resolution failed for command -> " .. tostring(sample_destination_site) .. "\n")
    os.exit(1)
end

local function check_alarm_outputs()
local original_redstone = redstone
local original_colors = colors
local original_command_broadcast = command_network.broadcast_command
local original_command_wait_for_result = command_network.wait_for_result
local alarm_redstone_outputs = {}
local alarm_bundled_outputs = {}
local alarm_requests = {}
redstone = {
    setOutput = function(side, value)
        alarm_redstone_outputs[side] = value
    end,
    setBundledOutput = function(side, value)
        alarm_bundled_outputs[side] = value
    end,
}
colors = {
    orange = 1,
    magenta = 2,
    blue = 4,
    green = 8,
    red = 16,
    lightBlue = 32,
    brown = 64,
    gray = 128,
}
command_network.broadcast_command = function(_config, payload)
    alarm_requests[#alarm_requests + 1] = {
        action = payload.command.action,
        target_site = payload.target_site,
        target_role = payload.target_role,
    }

    local message_id = payload.target_role == "gate_controller" and "alarm-gate-status-1" or "alarm-site-status-1"
    return result.ok({
        msg_id = message_id,
    })
end
command_network.wait_for_result = function(_config, expected_reply_to, timeout_seconds, _logger)
    if timeout_seconds ~= command_timeout.for_action("status") then
        return result.err("unexpected_alarm_wait_arguments")
    end

    if expected_reply_to == "alarm-gate-status-1" then
        return result.ok({
            payload = {
                ok = true,
                result = {
                    state = {
                        connected = true,
                        open = true,
                        dialing_out = false,
                        partial_dial = false,
                        chevrons_engaged = 7,
                        activity = "incoming_connected",
                        connection_direction = "incoming",
                    },
                },
            },
        })
    end

    if expected_reply_to == "alarm-site-status-1" then
        return result.ok({
            payload = {
                ok = true,
                result = {
                    site_status = {
                        site = "command",
                        role = "site_controller",
                        healthy = true,
                        warnings_count = 0,
                        address_book_available = true,
                    },
                },
            },
        })
    end

    return result.err("unexpected_alarm_reply_to", {
        reply_to = expected_reply_to,
    })
end

local alarm_cycle = alarm_controller.run_once({
    config = {
        site = "command",
        role = "alarm_controller",
    },
    inbox = {},
    signal_state = alarm_signal.new_state(),
    alarm = {
        poll_interval_ms = 250,
        trigger_on_fault = true,
        outputs = {
            {
                driver = "redstone",
                side = "back",
                signal = "system_error",
                active_high = false,
            },
            {
                driver = "redstone",
                side = "right",
                signal = "connection_established",
                active_high = true,
            },
            {
                driver = "bundled",
                side = "left",
                channels = {
                    orange = "connection_established",
                    magenta = {
                        signal = "system_error",
                        mode = "pulse",
                    },
                },
            },
        },
        speaker = {
            bindings = {
                {
                    signal = "system_error",
                    pattern = "pattern_beta",
                },
            },
        },
    },
}, nil)

if not alarm_cycle.ok
    or alarm_cycle.value.signals.connection_established ~= true
    or alarm_cycle.value.signals.connection_disconnected ~= false
    or alarm_cycle.value.signals.system_error ~= false
    or #alarm_requests ~= 2
    or alarm_requests[1].target_role ~= "gate_controller"
    or alarm_requests[2].target_role ~= "site_controller"
    or alarm_redstone_outputs.back ~= true
    or alarm_redstone_outputs.right ~= true
    or alarm_bundled_outputs.left ~= colors.orange
then
    io.stderr:write("Alarm controller active output failed\n")
    os.exit(1)
end

command_network.wait_for_result = function(_config, expected_reply_to, _timeout_seconds, _logger)
    if expected_reply_to == "alarm-gate-status-1" then
        return result.err("command_timeout")
    end

    return result.ok({
        payload = {
            ok = true,
            result = {
                site_status = {
                    site = "command",
                    role = "site_controller",
                    healthy = true,
                    warnings_count = 0,
                    address_book_available = true,
                },
            },
        },
    })
end

local alarm_fault_cycle = alarm_controller.run_once({
    config = {
        site = "command",
        role = "alarm_controller",
    },
    inbox = {},
    signal_state = alarm_signal.new_state(),
    alarm = {
        poll_interval_ms = 250,
        trigger_on_fault = true,
        outputs = {
            {
                driver = "redstone",
                side = "left",
                signal = "system_error",
                active_high = true,
            },
        },
    },
}, nil)

redstone = original_redstone
colors = original_colors
command_network.broadcast_command = original_command_broadcast
command_network.wait_for_result = original_command_wait_for_result

if not alarm_fault_cycle.ok
    or alarm_fault_cycle.value.signals.system_error ~= true
    or alarm_fault_cycle.value.gate_fault ~= "command_timeout"
    or alarm_redstone_outputs.left ~= true
then
    io.stderr:write("Alarm controller fault output failed\n")
    os.exit(1)
end

do
    redstone = {
        setOutput = function(side, value)
            alarm_redstone_outputs[side] = value
        end,
        setBundledOutput = function(side, value)
            alarm_bundled_outputs[side] = value
        end,
    }
    colors = {
        orange = 1,
        blue = 4,
        red = 2,
        magenta = 8,
        combine = function(...)
            local mask = 0
            for index = 1, select("#", ...) do
                mask = mask + select(index, ...)
            end
            return mask
        end,
    }

    local cleared_active_low_output = alarm_output.clear({
        {
            driver = "redstone",
            side = "top",
            signal = "connection_established",
            active_high = false,
        },
    })
    local applied_incoming_redstone_output = alarm_output.apply({
        {
            driver = "redstone",
            side = "front",
            signal = "connection_incoming",
            active_high = true,
        },
    }, {
        connection_incoming = true,
    })
    local applied_dialing_redstone_output = alarm_output.apply({
        {
            driver = "redstone",
            side = "bottom",
            signal = "dialing",
            active_high = true,
        },
    }, {
        dialing = true,
    })
    local applied_bundled_output = alarm_output.apply({
        {
            driver = "bundled",
            side = "back",
            channels = {
                orange = "connection_established",
                blue = "wormhole_incoming",
            },
        },
    }, {
        connection_established = true,
        wormhole_incoming = true,
        system_error = false,
    })
    local pulse_output_state = alarm_output.new_state()
    local pulse_dialing_output_state = alarm_output.new_state()
    local manual_override_state = alarm_output.new_state()
    local pulsed_dialing_redstone_output = alarm_output.apply({
        {
            driver = "redstone",
            side = "right",
            signal = {
                signal = "dialing",
                mode = "pulse",
            },
            active_high = true,
        },
    }, {
        dialing = true,
    }, pulse_dialing_output_state, 1000)
    local pulsed_dialing_redstone_output_expired = alarm_output.apply({
        {
            driver = "redstone",
            side = "right",
            signal = {
                signal = "dialing",
                mode = "pulse",
            },
            active_high = true,
        },
    }, {
        dialing = true,
    }, pulse_dialing_output_state, 2100)
    local pulsed_system_error = alarm_output.apply({
        {
            driver = "bundled",
            side = "left",
            channels = {
                magenta = {
                    signal = "system_error",
                    mode = "pulse",
                },
            },
        },
    }, {
        system_error = true,
    }, pulse_output_state, 1000)
    local pulsed_system_error_held = alarm_output.apply({
        {
            driver = "bundled",
            side = "left",
            channels = {
                magenta = {
                    signal = "system_error",
                    mode = "pulse",
                },
            },
        },
    }, {
        system_error = true,
    }, pulse_output_state, 1500)
    local pulsed_system_error_expired = alarm_output.apply({
        {
            driver = "bundled",
            side = "left",
            channels = {
                magenta = {
                    signal = "system_error",
                    mode = "pulse",
                },
            },
        },
    }, {
        system_error = true,
    }, pulse_output_state, 2100)
    alarm_output.set_override(manual_override_state, "redstone:right", false, true)
    local applied_manual_override_redstone_output = alarm_output.apply({
        {
            driver = "redstone",
            side = "right",
            signal = "system_error",
            active_high = true,
        },
    }, {
        system_error = true,
    }, manual_override_state, 1000)
    alarm_output.set_override(manual_override_state, "bundled:back:orange", false, true)
    local applied_manual_override_bundled_output = alarm_output.apply({
        {
            driver = "bundled",
            side = "back",
            channels = {
                orange = "connection_established",
            },
        },
    }, {
        connection_established = true,
    }, manual_override_state, 1000)

    redstone = original_redstone
    colors = original_colors

    if not cleared_active_low_output.ok
        or alarm_redstone_outputs.top ~= true
        or not applied_incoming_redstone_output.ok
        or alarm_redstone_outputs.front ~= true
        or not applied_dialing_redstone_output.ok
        or alarm_redstone_outputs.bottom ~= true
        or not pulsed_dialing_redstone_output.ok
        or pulsed_dialing_redstone_output.value[1].value ~= true
        or not pulsed_dialing_redstone_output_expired.ok
        or alarm_redstone_outputs.right ~= false
        or not applied_bundled_output.ok
        or applied_bundled_output.value[1].value ~= 5
        or not pulsed_system_error.ok
        or pulsed_system_error.value[1].value ~= 8
        or not pulsed_system_error_held.ok
        or pulsed_system_error_held.value[1].value ~= 8
        or not pulsed_system_error_expired.ok
        or pulsed_system_error_expired.value[1].value ~= 0
        or not applied_manual_override_redstone_output.ok
        or applied_manual_override_redstone_output.value[1].value ~= false
        or not applied_manual_override_bundled_output.ok
        or applied_manual_override_bundled_output.value[1].value ~= 0
    then
        io.stderr:write("Alarm output clearing or bundled mask handling failed\n")
        os.exit(1)
    end
end
end
check_alarm_outputs()

local function check_section_7()
do
    local original_peripheral_speaker = peripheral
    local speaker_calls = {}
    peripheral = {
        wrap = function(side)
            if side ~= "top" then
                return nil
            end

            return {
                getNamesRemote = function()
                    return { "speaker_0", "speaker_1" }
                end,
                hasTypeRemote = function(remote_name, wanted_type)
                    return (remote_name == "speaker_0" or remote_name == "speaker_1") and wanted_type == "speaker"
                end,
                callRemote = function(remote_name, method_name, ...)
                    if remote_name ~= "speaker_0" and remote_name ~= "speaker_1" then
                        error("unexpected remote speaker " .. tostring(remote_name))
                    end

                    if method_name == "stop" then
                        speaker_calls[#speaker_calls + 1] = remote_name .. ":stop"
                        return
                    end

                    if method_name == "playNote" then
                        local instrument, volume, pitch = ...
                        speaker_calls[#speaker_calls + 1] =
                            remote_name
                            .. ":playNote:"
                            .. tostring(instrument)
                            .. ":"
                            .. tostring(volume)
                            .. ":"
                            .. tostring(pitch)
                        return true
                    end

                    error("unexpected remote speaker method " .. tostring(method_name))
                end,
            }
        end,
    }

    local incoming_override_runtime = alarm_speaker.new_runtime({
        bindings = {
            {
                signal = "connection_incoming",
                pattern = "pattern_alpha",
            },
            {
                signal = "system_error",
                pattern = "pattern_beta",
            },
        },
        peripheral_side = "top",
    })
    local incoming_override_play = alarm_speaker.update(incoming_override_runtime, {
        connection_incoming = true,
        system_error = true,
    })

    local ordered_runtime = alarm_speaker.new_runtime({
        bindings = {
            {
                signal = "connection_outgoing",
                pattern = "pattern_alpha",
            },
            {
                signal = "system_error",
                pattern = "pattern_beta",
            },
        },
        peripheral_side = "top",
    })
    local ordered_play = alarm_speaker.update(ordered_runtime, {
        connection_outgoing = true,
        system_error = true,
    })
    local ordered_stop = alarm_speaker.update(ordered_runtime, {})
    local dialing_runtime = alarm_speaker.new_runtime({
        bindings = {
            {
                signal = "dialing",
                pattern = "pattern_beta",
            },
        },
        peripheral_side = "top",
    })
    local dialing_play = alarm_speaker.update(dialing_runtime, {
        dialing = true,
    })
    local manual_runtime = alarm_speaker.new_runtime({
        bindings = {
            {
                signal = "connection_incoming",
                pattern = "pattern_alpha",
            },
            {
                signal = "system_error",
                pattern = "pattern_beta",
            },
        },
        peripheral_side = "top",
    })
    local manual_snapshot_before = alarm_speaker.snapshot(manual_runtime, manual_runtime.bindings, {})
    local manual_override_enabled = alarm_speaker.toggle_override(manual_runtime, "speaker:1", false, false)
    local manual_play = alarm_speaker.update(manual_runtime, {})
    local manual_snapshot_after = alarm_speaker.snapshot(manual_runtime, manual_runtime.bindings, {})
    local manual_override_disabled = alarm_speaker.toggle_override(manual_runtime, "speaker:1", true, false)
    local manual_stop = alarm_speaker.update(manual_runtime, {})

    peripheral = {
        wrap = function(_side)
            return nil
        end,
    }
    local optional_runtime = alarm_speaker.new_runtime({
        bindings = {
            {
                signal = "system_error",
                pattern = "pattern_beta",
            },
        },
        peripheral_side = "top",
    })
    local optional_play = alarm_speaker.update(optional_runtime, {
        system_error = true,
    })

    peripheral = original_peripheral_speaker

    if not incoming_override_play.ok
        or incoming_override_play.value.signal ~= "system_error"
        or incoming_override_play.value.pattern ~= "pattern_beta"
        or speaker_calls[1] ~= "speaker_0:playNote:didgeridoo:3.0:6"
        or speaker_calls[2] ~= "speaker_1:playNote:didgeridoo:3.0:6"
        or not ordered_play.ok
        or ordered_play.value.signal ~= "connection_outgoing"
        or ordered_play.value.pattern ~= "pattern_alpha"
        or speaker_calls[3] ~= "speaker_0:playNote:didgeridoo:3.0:8"
        or speaker_calls[4] ~= "speaker_1:playNote:didgeridoo:3.0:8"
        or not ordered_stop.ok
        or speaker_calls[5] ~= "speaker_0:stop"
        or speaker_calls[6] ~= "speaker_1:stop"
        or not dialing_play.ok
        or dialing_play.value.signal ~= "dialing"
        or dialing_play.value.pattern ~= "pattern_beta"
        or speaker_calls[7] ~= "speaker_0:playNote:didgeridoo:3.0:6"
        or speaker_calls[8] ~= "speaker_1:playNote:didgeridoo:3.0:6"
        or manual_snapshot_before[1].active ~= false
        or manual_override_enabled ~= true
        or not manual_play.ok
        or manual_play.value.signal ~= "connection_incoming"
        or manual_play.value.pattern ~= "pattern_alpha"
        or speaker_calls[9] ~= "speaker_0:playNote:didgeridoo:3.0:8"
        or speaker_calls[10] ~= "speaker_1:playNote:didgeridoo:3.0:8"
        or manual_snapshot_after[1].active ~= true
        or manual_snapshot_after[1].override_active ~= true
        or manual_override_disabled ~= false
        or not manual_stop.ok
        or speaker_calls[11] ~= "speaker_0:stop"
        or speaker_calls[12] ~= "speaker_1:stop"
        or not optional_play.ok
        or optional_play.value.playing ~= false
        or optional_play.value.signal ~= "system_error"
        or optional_play.value.pattern ~= "pattern_beta"
        or optional_play.value.unavailable ~= true
    then
        io.stderr:write("Alarm speaker selection or precedence failed\n")
        os.exit(1)
    end
end
end
check_section_7()

local function check_section_8()
do
    local incoming_partial_dial_signals = alarm_signal.evaluate({
        pulse_until = {
            wormhole_incoming = 2000,
        },
    }, {
        gate_state = {
            connected = true,
        },
        site_status = {
            healthy = true,
        },
        trigger_on_fault = true,
    }, 1000)
    if incoming_partial_dial_signals.connection_established ~= true
        or incoming_partial_dial_signals.connection_incoming ~= false
        or incoming_partial_dial_signals.connection_outgoing ~= false
        or incoming_partial_dial_signals.dialing ~= false
        or incoming_partial_dial_signals.wormhole_incoming ~= true
        or incoming_partial_dial_signals.system_error ~= false
    then
        io.stderr:write("Alarm signal event evaluation failed\n")
        os.exit(1)
    end

    local dialing_signals = alarm_signal.evaluate(alarm_signal.new_state(), {
        gate_state = {
            connected = false,
            open = false,
            partial_dial = false,
            dialing_out = true,
            activity = "dialing_out",
            connection_direction = "outgoing",
        },
        site_status = {
            healthy = true,
        },
        trigger_on_fault = true,
    }, 1000)
    if dialing_signals.dialing ~= true
        or dialing_signals.connection_established ~= false
        or dialing_signals.connection_outgoing ~= false
    then
        io.stderr:write("Alarm dialing signal evaluation failed\n")
        os.exit(1)
    end

    local outgoing_partial_dial_signals = alarm_signal.evaluate(alarm_signal.new_state(), {
        gate_state = {
            connected = false,
            open = false,
            partial_dial = true,
            dialing_out = false,
            activity = "partial_dial",
            connection_direction = "outgoing",
        },
        site_status = {
            healthy = true,
        },
        trigger_on_fault = true,
    }, 1000)
    if outgoing_partial_dial_signals.dialing ~= true then
        io.stderr:write("Alarm outgoing partial dial signal evaluation failed\n")
        os.exit(1)
    end

    local disconnect_signal_state = alarm_signal.new_state()
    alarm_signal.observe_gate_state(disconnect_signal_state, {
        connected = true,
    }, {
        connected = false,
    }, 1000)
    local disconnected_signals = alarm_signal.evaluate(disconnect_signal_state, {
        gate_state = {
            connected = false,
        },
        site_status = {
            healthy = true,
        },
        trigger_on_fault = true,
    }, 1000)
    if disconnected_signals.connection_disconnected ~= true or disconnected_signals.connection_established ~= false then
        io.stderr:write("Alarm signal disconnect transition evaluation failed\n")
        os.exit(1)
    end

    local outgoing_wormhole_cycle_state = alarm_signal.new_state()
    alarm_signal.activate_pulse(outgoing_wormhole_cycle_state, "wormhole_outgoing", 1000)
    local first_outgoing_expiry = outgoing_wormhole_cycle_state.pulse_until.wormhole_outgoing
    alarm_signal.observe_gate_state(outgoing_wormhole_cycle_state, {
        connected = false,
        open = false,
        partial_dial = true,
        dialing_out = false,
        activity = "partial_dial",
        connection_direction = "outgoing",
    }, {
        connected = false,
        open = true,
        partial_dial = false,
        dialing_out = false,
        activity = "outgoing_open",
        connection_direction = "outgoing",
    }, 1500)
    local deduped_outgoing_expiry = outgoing_wormhole_cycle_state.pulse_until.wormhole_outgoing
    alarm_signal.observe_gate_state(outgoing_wormhole_cycle_state, {
        connected = false,
        open = true,
        partial_dial = false,
        dialing_out = false,
        activity = "outgoing_open",
        connection_direction = "outgoing",
    }, {
        connected = false,
        open = false,
        partial_dial = false,
        dialing_out = false,
        activity = "idle",
        connection_direction = nil,
    }, 2000)
    alarm_signal.activate_pulse(outgoing_wormhole_cycle_state, "wormhole_outgoing", 2500)
    local second_outgoing_expiry = outgoing_wormhole_cycle_state.pulse_until.wormhole_outgoing
    if first_outgoing_expiry ~= 1000 + constants.ALARM_PULSE_DURATION_MS
        or deduped_outgoing_expiry ~= first_outgoing_expiry
        or second_outgoing_expiry ~= 2500 + constants.ALARM_PULSE_DURATION_MS
    then
        io.stderr:write("Alarm wormhole outgoing pulse dedupe failed\n")
        os.exit(1)
    end

    local incoming_wormhole_cycle_state = alarm_signal.new_state()
    alarm_signal.observe_gate_state(incoming_wormhole_cycle_state, {
        connected = false,
        open = false,
        partial_dial = false,
        dialing_out = false,
        activity = "idle",
        connection_direction = nil,
    }, {
        connected = false,
        open = true,
        partial_dial = false,
        dialing_out = false,
        activity = "incoming_open",
        connection_direction = "incoming",
    }, 3000)
    local first_incoming_expiry = incoming_wormhole_cycle_state.pulse_until.wormhole_incoming
    alarm_signal.activate_pulse(incoming_wormhole_cycle_state, "wormhole_incoming", 3500)
    local deduped_incoming_expiry = incoming_wormhole_cycle_state.pulse_until.wormhole_incoming
    alarm_signal.observe_gate_state(incoming_wormhole_cycle_state, {
        connected = false,
        open = true,
        partial_dial = false,
        dialing_out = false,
        activity = "incoming_open",
        connection_direction = "incoming",
    }, {
        connected = false,
        open = false,
        partial_dial = false,
        dialing_out = false,
        activity = "idle",
        connection_direction = nil,
    }, 4000)
    alarm_signal.observe_gate_state(incoming_wormhole_cycle_state, {
        connected = false,
        open = false,
        partial_dial = false,
        dialing_out = false,
        activity = "idle",
        connection_direction = nil,
    }, {
        connected = false,
        open = true,
        partial_dial = false,
        dialing_out = false,
        activity = "incoming_open",
        connection_direction = "incoming",
    }, 4500)
    local second_incoming_expiry = incoming_wormhole_cycle_state.pulse_until.wormhole_incoming
    if first_incoming_expiry ~= 3000 + constants.ALARM_PULSE_DURATION_MS
        or deduped_incoming_expiry ~= first_incoming_expiry
        or second_incoming_expiry ~= 4500 + constants.ALARM_PULSE_DURATION_MS
    then
        io.stderr:write("Alarm wormhole incoming pulse dedupe failed\n")
        os.exit(1)
    end

    local incoming_connected_signals = alarm_signal.evaluate(alarm_signal.new_state(), {
        gate_state = {
            connected = true,
            connection_direction = "incoming",
        },
        site_status = {
            healthy = true,
        },
        trigger_on_fault = true,
    }, 1000)
    if incoming_connected_signals.connection_incoming ~= true
        or incoming_connected_signals.connection_outgoing ~= false
    then
        io.stderr:write("Alarm incoming connection signal evaluation failed\n")
        os.exit(1)
    end

    local outgoing_connected_signals = alarm_signal.evaluate(alarm_signal.new_state(), {
        gate_state = {
            connected = true,
            connection_direction = "outgoing",
        },
        site_status = {
            healthy = true,
        },
        trigger_on_fault = true,
    }, 1000)
    if outgoing_connected_signals.connection_incoming ~= false
        or outgoing_connected_signals.connection_outgoing ~= true
        or outgoing_connected_signals.dialing ~= false
    then
        io.stderr:write("Alarm outgoing connection signal evaluation failed\n")
        os.exit(1)
    end

    ;(function()
        local function find_upvalue(func, wanted_name)
            for index = 1, 64 do
                local upvalue_name, upvalue_value = debug.getupvalue(func, index)
                if upvalue_name == nil then
                    return nil
                end
                if upvalue_name == wanted_name then
                    return upvalue_value
                end
            end

            return nil
        end

        local time_module = require("core.time")
        local serve_receive_loop = find_upvalue(alarm_controller.start, "serve_receive_loop")
        local evaluate_runtime = serve_receive_loop ~= nil and find_upvalue(serve_receive_loop, "evaluate_runtime") or nil
        local stale_timeout_ms = evaluate_runtime ~= nil and find_upvalue(evaluate_runtime, "stale_timeout_ms") or nil
        local original_time_now_ms = time_module.now_ms
        local now_ms = 0

        local function build_alarm_runtime(gate_state_snapshot)
            return {
                config = {},
                alarm = {
                    trigger_on_fault = true,
                    outputs = {},
                    speaker = {
                        bindings = {},
                        peripheral_side = nil,
                    },
                },
                speaker = alarm_speaker.new_runtime({
                    bindings = {},
                    peripheral_side = nil,
                }),
                signal_state = alarm_signal.new_state(),
                output_state = alarm_output.new_state(),
                monitor = alarm_monitor.new_state(),
                last_gate_fault = nil,
                last_site_fault = nil,
                last_gate_state = gate_state_snapshot,
                last_gate_state_at = 0,
                last_site_status = {
                    site = "command",
                    role = "site_controller",
                    healthy = true,
                    warnings_count = 0,
                    address_book_available = true,
                },
                last_site_status_at = 0,
            }
        end

        time_module.now_ms = function()
            return now_ms
        end

        local active_gate_state = {
            connected = false,
            open = false,
            partial_dial = true,
            dialing_out = false,
            activity = "partial_dial",
            connection_direction = "outgoing",
        }
        local active_timeout = stale_timeout_ms ~= nil and stale_timeout_ms(active_gate_state) or nil

        now_ms = 120000
        local active_before_timeout = evaluate_runtime ~= nil and evaluate_runtime(build_alarm_runtime(active_gate_state), nil) or nil

        now_ms = 6000
        local idle_after_timeout = evaluate_runtime ~= nil and evaluate_runtime(build_alarm_runtime({
            connected = false,
            open = false,
            partial_dial = false,
            dialing_out = false,
            activity = "idle",
            connection_direction = nil,
        }), nil) or nil

        now_ms = type(active_timeout) == "number" and active_timeout + 1 or 180001
        local active_after_timeout = evaluate_runtime ~= nil and evaluate_runtime(build_alarm_runtime(active_gate_state), nil) or nil

        time_module.now_ms = original_time_now_ms

        if serve_receive_loop == nil
            or evaluate_runtime == nil
            or stale_timeout_ms == nil
            or type(active_timeout) ~= "number"
            or active_timeout < 180000
            or not active_before_timeout.ok
            or active_before_timeout.value.site_fault ~= nil
            or active_before_timeout.value.site_status == nil
            or not idle_after_timeout.ok
            or idle_after_timeout.value.site_fault ~= "stale_site_status"
            or idle_after_timeout.value.site_status ~= nil
            or not active_after_timeout.ok
            or active_after_timeout.value.site_fault ~= "stale_site_status"
            or active_after_timeout.value.site_status ~= nil
        then
            io.stderr:write("Alarm active dial stale timeout evaluation failed\n")
            os.exit(1)
        end
    end)()

    local invalid_alarm_speaker_pattern = config_schema.validate(config_defaults.for_role("alarm_controller", {
        alarm = {
            speaker = {
                bindings = {
                    {
                        signal = "system_error",
                        pattern = "bad_pattern",
                    },
                },
            },
        },
    }))
    if invalid_alarm_speaker_pattern.ok then
        io.stderr:write("Alarm config validation unexpectedly accepted invalid speaker pattern\n")
        os.exit(1)
    end
end

local function check_alarm_controller_start()
    local original_sleep = sleep
    local original_peripheral = peripheral
    local original_transport_open = rednet_transport.open
    local original_transport_receive_alarm_start = rednet_transport.receive
    local original_command_broadcast = command_network.broadcast_command
    local original_command_wait_for_result = command_network.wait_for_result
    local startup_redstone_calls = {}
    local startup_speaker_calls = {}
    local startup_alarm_requests = {}
    local startup_alarm_wait_count = 0
    local startup_redstone_call_count = 0
    local startup_alarm_state_events = 0

    redstone = {
        setOutput = function(side, value)
            startup_redstone_call_count = startup_redstone_call_count + 1
            startup_redstone_calls[#startup_redstone_calls + 1] = "redstone:" .. tostring(side) .. ":" .. tostring(value)
            if startup_redstone_call_count > 7 then
                error("stop_alarm_start_test")
            end
        end,
        setBundledOutput = function(side, value)
            startup_redstone_calls[#startup_redstone_calls + 1] = "bundled:" .. tostring(side) .. ":" .. tostring(value)
        end,
    }
    colors = {
        orange = 1,
        red = 2,
        black = 4,
    }
    peripheral = {
        wrap = function(side)
            if side ~= "top" then
                return nil
            end

            return {
                getNamesRemote = function()
                    return { "speaker_0", "speaker_1" }
                end,
                hasTypeRemote = function(remote_name, wanted_type)
                    return (remote_name == "speaker_0" or remote_name == "speaker_1") and wanted_type == "speaker"
                end,
                callRemote = function(remote_name, method_name, ...)
                    if remote_name ~= "speaker_0" and remote_name ~= "speaker_1" then
                        error("unexpected remote speaker " .. tostring(remote_name))
                    end

                    if method_name == "stop" then
                        startup_speaker_calls[#startup_speaker_calls + 1] = remote_name .. ":stop"
                        return
                    end

                    if method_name == "playNote" then
                        local instrument, volume, pitch = ...
                        startup_speaker_calls[#startup_speaker_calls + 1] =
                            remote_name
                            .. ":playNote:"
                            .. tostring(instrument)
                            .. ":"
                            .. tostring(volume)
                            .. ":"
                            .. tostring(pitch)
                        return true
                    end

                    error("unexpected remote speaker method " .. tostring(method_name))
                end,
            }
        end,
    }
    rednet_transport.open = function(_side)
        return result.ok(true)
    end
    rednet_transport.receive = (function()
        local gate_state_event = envelope.new("state", "command", "gate_controller", gate_message.build_state_payload({
            side = "left",
            interface_type = "advanced_crystal_interface",
            connected = true,
            open = true,
            dialing_out = false,
            activity = "incoming_connected",
            connection_direction = "incoming",
            idle = false,
            partial_dial = false,
            local_address = { 1, 2, 3, 4, 5, 6 },
            dialed_address = { 1, 2, 3, 4, 5, 6, 0 },
            connected_address = { 1, 2, 3, 4, 5, 6, 0 },
            chevrons_engaged = 7,
            stargate_generation = 2,
            current_symbol = 0,
            energy = {
                stored = 1000,
                capacity = 1000,
                available = true,
            },
            iris = {
                supported = false,
                identifier = nil,
                installed = nil,
                progress = nil,
                progress_percent = nil,
            },
        }, 1, 111111))
        local site_status_event =
            envelope.new("state", "command", "site_controller", site_message.build_status_payload({
                site = "command",
                role = "site_controller",
                healthy = true,
                warnings_count = 0,
                address_book_available = true,
                address_book_error = nil,
                last_internal_error = nil,
                started_at = 1,
            }, 1, 111112))
        local queued = {
            gate_state_event.ok and {
                sender_id = 77,
                protocol = constants.PROTOCOLS.state,
                envelope = gate_state_event.value,
            } or nil,
            site_status_event.ok and {
                sender_id = 78,
                protocol = constants.PROTOCOLS.state,
                envelope = site_status_event.value,
            } or nil,
        }

        return function(_config, _timeout, _accepted_protocols)
            local next_event = table.remove(queued, 1)
            if next_event ~= nil then
                startup_alarm_state_events = startup_alarm_state_events + 1
                return result.ok(next_event)
            end

            return result.err("receive_timeout")
        end
    end)()
    command_network.broadcast_command = function(_config, payload)
        startup_alarm_requests[#startup_alarm_requests + 1] = payload.target_role .. ":" .. payload.command.action
        local prefix = payload.target_role == "gate_controller" and "gate" or "site"
        return result.ok({
            msg_id = prefix .. "-startup-" .. tostring(#startup_alarm_requests),
        })
    end
    command_network.wait_for_result = function(_config, expected_reply_to, _timeout_seconds, _logger)
        startup_alarm_wait_count = startup_alarm_wait_count + 1
        if startup_alarm_wait_count <= 2 then
            if expected_reply_to:match("^gate") then
                return result.ok({
                    payload = {
                        ok = true,
                        result = {
                            state = {
                                connected = true,
                                open = true,
                                dialing_out = false,
                                partial_dial = false,
                                chevrons_engaged = 7,
                                activity = "incoming_connected",
                                connection_direction = "incoming",
                            },
                        },
                    },
                })
            end

            return result.ok({
                payload = {
                    ok = true,
                    result = {
                        site_status = {
                            site = "command",
                            role = "site_controller",
                            healthy = true,
                            warnings_count = 0,
                            address_book_available = true,
                        },
                    },
                },
            })
        end

        return result.err("command_timeout")
    end
    sleep = function(_seconds)
    end

    local started_alarm_controller = alarm_controller.start({
        site = "command",
        role = "alarm_controller",
        modems = {
            site = "bottom",
            peripheral = "top",
        },
        alarm = {
            trigger_on_fault = true,
            outputs = config_defaults.for_role("alarm_controller").alarm.outputs,
            speaker = config_defaults.for_role("alarm_controller").alarm.speaker,
        },
    }, nil)

    redstone = original_redstone
    colors = original_colors
    peripheral = original_peripheral
    rednet_transport.open = original_transport_open
    rednet_transport.receive = original_transport_receive_alarm_start
    command_network.broadcast_command = original_command_broadcast
    command_network.wait_for_result = original_command_wait_for_result
    sleep = original_sleep

    if started_alarm_controller.ok
        or started_alarm_controller.error ~= "redstone_output_failed"
        or startup_redstone_calls[1] ~= "redstone:left:false"
        or startup_redstone_calls[2] ~= "redstone:right:false"
        or startup_redstone_calls[3] ~= "bundled:back:0"
        or startup_speaker_calls[1] ~= "speaker_0:stop"
        or startup_speaker_calls[2] ~= "speaker_1:stop"
        or startup_speaker_calls[3] ~= "speaker_0:playNote:didgeridoo:3.0:8"
        or startup_speaker_calls[4] ~= "speaker_1:playNote:didgeridoo:3.0:8"
        or startup_alarm_requests[1] ~= "gate_controller:status"
        or startup_alarm_requests[2] ~= "site_controller:status"
        or startup_alarm_state_events ~= 2
    then
        io.stderr:write("Alarm controller startup clear or speaker behavior failed\n")
        os.exit(1)
    end
end

check_alarm_controller_start()

local hello = envelope.new("hello", "command", "site_controller", {
    probe = true,
})
if not hello.ok then
    io.stderr:write("Envelope creation failed\n")
    os.exit(1)
end

local site_command_request = {
    action = "dial",
    request_id = "req-1",
    destination_site = sample_destination_site,
    dial_mode = "auto",
}

local validated_site_command = command_schema.validate_site_command_request(site_command_request)
if not validated_site_command.ok then
    io.stderr:write("Site command validation failed\n")
    os.exit(1)
end

local planned_command = site_command.plan(validation.value, "command", site_command_request)
if not planned_command.ok then
    io.stderr:write("Site command planning failed\n")
    os.exit(1)
end

if planned_command.value.action ~= "dial" or type(planned_command.value.address) ~= "table" then
    io.stderr:write("Site command planning did not resolve a dial address\n")
    os.exit(1)
end

if planned_command.value.dial_mode ~= "auto" then
    io.stderr:write("Site command planning did not preserve dial mode\n")
    os.exit(1)
end

local invalid_disconnect_command = command_schema.validate_gate_command({
    action = "disconnect",
    address = { 1, 2, 3, 4, 5, 6 },
})
if invalid_disconnect_command.ok then
    io.stderr:write("Gate command validation unexpectedly accepted address on disconnect\n")
    os.exit(1)
end

local invalid_disconnect_dial_mode = command_schema.validate_gate_command({
    action = "disconnect",
    dial_mode = "slow",
})
if invalid_disconnect_dial_mode.ok then
    io.stderr:write("Gate command validation unexpectedly accepted dial mode on disconnect\n")
    os.exit(1)
end

local invalid_site_reset = command_schema.validate_site_command_request({
    action = "reset",
})
if invalid_site_reset.ok then
    io.stderr:write("Site command validation unexpectedly accepted reset action\n")
    os.exit(1)
end

local valid_site_status = command_schema.validate_site_command_request({
    action = "status",
})
if not valid_site_status.ok then
    io.stderr:write("Site command validation rejected status action\n")
    os.exit(1)
end

local valid_medium_dial_mode = command_schema.validate_gate_command({
    action = "dial",
    address = { 1, 2, 3, 4, 5, 6 },
    dial_mode = "medium",
})
if not valid_medium_dial_mode.ok then
    io.stderr:write("Gate command validation rejected medium dial mode\n")
    os.exit(1)
end

local valid_galactic_with_origin = command_schema.validate_gate_command({
    action = "dial",
    address = { 1, 2, 3, 4, 5, 6, 7, 8, 0 },
})
if not valid_galactic_with_origin.ok then
    io.stderr:write("Gate command validation rejected galactic address with point of origin\n")
    os.exit(1)
end

local valid_gate_reset = command_schema.validate_gate_command({
    action = "reset",
})
if not valid_gate_reset.ok then
    io.stderr:write("Gate command validation rejected reset action\n")
    os.exit(1)
end

local valid_gate_status = command_schema.validate_gate_command({
    action = "status",
})
if not valid_gate_status.ok then
    io.stderr:write("Gate command validation rejected status action\n")
    os.exit(1)
end

if command_timeout.for_action("dial") ~= constants.DEFAULT_DIAL_COMMAND_TIMEOUT_SECONDS
    or command_timeout.for_action("status") ~= constants.DEFAULT_STATUS_COMMAND_TIMEOUT_SECONDS
    or command_timeout.for_action("disconnect") ~= constants.DEFAULT_COMMAND_TIMEOUT_SECONDS
then
    io.stderr:write("Command timeout resolution failed\n")
    os.exit(1)
end

local original_gate_controller_execute = gate_controller.execute
local original_command_send_result_reply = command_network.send_result_reply
local gate_controller_reply = nil
gate_controller.execute = function(_instance, payload)
    return result.ok({
        action = payload.action,
        state = {
            side = "left",
            interface_type = "advanced_crystal_interface",
            connected = true,
            open = true,
            dialing_out = false,
            idle = false,
            partial_dial = false,
            chevrons_engaged = 7,
            energy = {
                stored = 1000,
                capacity = 2000,
                available = true,
            },
            iris = {
                supported = true,
            },
        },
    })
end
command_network.send_result_reply = function(_config, receiver_id, request_envelope, payload)
    gate_controller_reply = {
        receiver_id = receiver_id,
        request_envelope = request_envelope,
        payload = payload,
    }
    return result.ok(true)
end

local incoming_gate_request = envelope.new("command", "command", "alarm_controller", command_message.build_gate_request_payload(
    "command",
    {
        action = "status",
        request_id = "req-gate-status",
    }
))
if not incoming_gate_request.ok then
    io.stderr:write("Gate controller status envelope creation failed\n")
    os.exit(1)
end

local gate_runtime = {
    interface = {},
    state = nil,
    connection_direction = nil,
}
local handled_gate_status = gate_controller.handle_command({
    site = "command",
    role = "gate_controller",
}, gate_runtime, {
    sender_id = 12,
    protocol = constants.PROTOCOLS.command,
    envelope = incoming_gate_request.value,
})

gate_controller.execute = original_gate_controller_execute
command_network.send_result_reply = original_command_send_result_reply

if not handled_gate_status.ok
    or gate_controller_reply == nil
    or gate_controller_reply.payload.result == nil
    or gate_controller_reply.payload.result.state.connection_direction ~= "incoming"
    or gate_controller_reply.payload.result.state.activity ~= "incoming_connected"
then
    io.stderr:write("Gate controller did not enrich incoming gate status\n")
    os.exit(1)
end

local original_site_send_result_reply = command_network.send_result_reply
local site_status_reply = nil
command_network.send_result_reply = function(_config, receiver_id, request_envelope, payload)
    site_status_reply = {
        receiver_id = receiver_id,
        request_envelope = request_envelope,
        payload = payload,
    }
    return result.ok(true)
end

local site_status_request = envelope.new("command", "command", "alarm_controller", command_message.build_site_request_payload(
    "command",
    {
        action = "status",
        request_id = "req-site-status",
    }
))
if not site_status_request.ok then
    io.stderr:write("Site controller status envelope creation failed\n")
    os.exit(1)
end

local handled_site_status = site_controller.handle_command({
    site = "command",
    role = "site_controller",
    modems = {
        peripheral = nil,
    },
}, {
    state = {
        started_at = 12345,
        modems = {
            site = true,
            intersite = true,
        },
    },
    warnings = {},
    address_book = {
        book = validation.value,
    },
    health = {
        last_internal_error = nil,
        internal_error_count = 0,
        last_internal_error_source = nil,
    },
    last_command = nil,
}, {
    sender_id = 13,
    protocol = constants.PROTOCOLS.command,
    envelope = site_status_request.value,
}, nil)

command_network.send_result_reply = original_site_send_result_reply

if not handled_site_status.ok
    or site_status_reply == nil
    or site_status_reply.payload.result == nil
    or site_status_reply.payload.result.site_status == nil
    or site_status_reply.payload.result.site_status.healthy ~= true
then
    io.stderr:write("Site controller did not return site status\n")
    os.exit(1)
end

local original_peripheral = peripheral
peripheral = {
    call = function(_side, method_name, ...)
        local args = { ... }
        if method_name == "disconnectStargate" then
            return true
        end

        if method_name == "isStargateConnected" then
            return false
        end

        if method_name == "isWormholeOpen" then
            return false
        end

        if method_name == "isStargateDialingOut" then
            return false
        end

        if method_name == "getEnergy" then
            return 1000
        end

        if method_name == "getEnergyCapacity" then
            return 2000
        end

        if method_name == "getLocalAddress" then
            return { 1, 2, 3, 4, 5, 6, 7, 8 }
        end

        if method_name == "getDialedAddress" then
            return {}
        end

        if method_name == "getConnectedAddress" then
            return nil
        end

        if method_name == "getIris" then
            return "shield"
        end

        if method_name == "getIrisProgress" then
            return 0
        end

        if method_name == "getIrisProgressPercentage" then
            return 0
        end

        error("unexpected method " .. tostring(method_name) .. " with " .. tostring(#args) .. " args")
    end,
}

local executed_command = gate_command.execute({
    side = "left",
    interface_type = "advanced_crystal_interface",
    capabilities = {
        energy = true,
        local_address = true,
        dialed_address = true,
        connected_address = true,
        state = true,
        disconnect = true,
        iris = true,
        direct_dial = true,
        stargate_info = true,
        rotation = true,
        chevron = true,
    },
}, {
    action = "disconnect",
    request_id = "req-2",
})

peripheral = original_peripheral

if not executed_command.ok then
    io.stderr:write("Gate command execution failed\n")
    os.exit(1)
end

if executed_command.value.action ~= "disconnect" or executed_command.value.state.connected ~= false then
    io.stderr:write("Gate command execution returned unexpected state\n")
    os.exit(1)
end

local reset_disconnect_count = 0
original_peripheral = peripheral
local reset_connected = true
local reset_open = true
local reset_dialing = true
local reset_chevrons = 3
local reset_disconnect_result = true
peripheral = {
    call = function(_side, method_name, ...)
        if method_name == "disconnectStargate" then
            reset_disconnect_count = reset_disconnect_count + 1
            reset_connected = false
            reset_open = false
            reset_dialing = false
            reset_chevrons = 0
            return reset_disconnect_result
        end

        if method_name == "isStargateConnected" then
            return reset_connected
        end

        if method_name == "isWormholeOpen" then
            return reset_open
        end

        if method_name == "isStargateDialingOut" then
            return reset_dialing
        end

        if method_name == "getChevronsEngaged" then
            return reset_chevrons
        end

        if method_name == "getStargateGeneration" then
            return 2
        end

        if method_name == "getCurrentSymbol" then
            return 7
        end

        if method_name == "getEnergy" then
            return 1000
        end

        if method_name == "getEnergyCapacity" then
            return 2000
        end

        if method_name == "getLocalAddress" then
            return { 1, 2, 3, 4, 5, 6, 7, 8 }
        end

        if method_name == "getDialedAddress" then
            return {}
        end

        if method_name == "getConnectedAddress" then
            return nil
        end

        if method_name == "getIris" then
            return "shield"
        end

        if method_name == "getIrisProgress" then
            return 0
        end

        if method_name == "getIrisProgressPercentage" then
            return 0
        end

        error("unexpected reset method " .. tostring(method_name))
    end,
}

local reset_command = gate_command.execute({
    side = "left",
    interface_type = "advanced_crystal_interface",
    capabilities = {
        energy = true,
        local_address = true,
        dialed_address = true,
        connected_address = true,
        state = true,
        disconnect = true,
        iris = true,
        direct_dial = true,
        stargate_info = true,
        rotation = true,
        chevron = true,
    },
}, {
    action = "reset",
    request_id = "req-reset",
})

peripheral = original_peripheral

if not reset_command.ok then
    io.stderr:write("Gate reset execution failed\n")
    os.exit(1)
end

if reset_disconnect_count ~= 1
    or reset_command.value.reset_performed ~= true
    or reset_command.value.state.idle ~= true
    or reset_command.value.state.partial_dial ~= false
    or reset_command.value.state.chevrons_engaged ~= 0
    or reset_command.value.state.current_symbol ~= 7
    or reset_command.value.state.stargate_generation ~= 2
then
    io.stderr:write("Gate reset execution returned unexpected state\n")
    os.exit(1)
end

reset_disconnect_count = 0
reset_connected = false
reset_open = false
reset_dialing = false
reset_chevrons = 6
reset_disconnect_result = false
original_peripheral = peripheral
peripheral = {
    call = function(_side, method_name, ...)
        if method_name == "disconnectStargate" then
            reset_disconnect_count = reset_disconnect_count + 1
            reset_chevrons = 0
            return reset_disconnect_result
        end

        if method_name == "isStargateConnected" then
            return reset_connected
        end

        if method_name == "isWormholeOpen" then
            return reset_open
        end

        if method_name == "isStargateDialingOut" then
            return reset_dialing
        end

        if method_name == "getChevronsEngaged" then
            return reset_chevrons
        end

        if method_name == "getStargateGeneration" then
            return 2
        end

        if method_name == "getCurrentSymbol" then
            return 7
        end

        if method_name == "getEnergy" then
            return 1000
        end

        if method_name == "getEnergyCapacity" then
            return 2000
        end

        if method_name == "getLocalAddress" then
            return { 1, 2, 3, 4, 5, 6, 7, 8 }
        end

        if method_name == "getDialedAddress" then
            return {}
        end

        if method_name == "getConnectedAddress" then
            return nil
        end

        if method_name == "getIris" then
            return "shield"
        end

        if method_name == "getIrisProgress" then
            return 0
        end

        if method_name == "getIrisProgressPercentage" then
            return 0
        end

        error("unexpected partial reset method " .. tostring(method_name))
    end,
}

local partial_reset_command = gate_command.execute({
    side = "left",
    interface_type = "advanced_crystal_interface",
    capabilities = {
        energy = true,
        local_address = true,
        dialed_address = true,
        connected_address = true,
        state = true,
        disconnect = true,
        iris = true,
        direct_dial = true,
        stargate_info = true,
        rotation = true,
        chevron = true,
    },
}, {
    action = "reset",
    request_id = "req-partial-reset",
})

peripheral = original_peripheral

if not partial_reset_command.ok
    or reset_disconnect_count ~= 1
    or partial_reset_command.value.reset_performed ~= true
    or partial_reset_command.value.state.idle ~= true
    or partial_reset_command.value.state.chevrons_engaged ~= 0
then
    io.stderr:write("Gate partial reset execution returned unexpected state\n")
    os.exit(1)
end

local original_gate_discover = gate_interface.discover
local original_gate_reset_to_idle = gate_command.reset_to_idle
local original_gate_state_read = gate_state.read
local original_transport_open = rednet_transport.open
gate_interface.discover = function()
    return result.ok({
        side = "left",
        interface_type = "advanced_crystal_interface",
        capabilities = {
            disconnect = true,
            stargate_info = true,
            rotation = true,
            state = true,
            iris = true,
            energy = true,
            local_address = true,
            dialed_address = true,
            connected_address = true,
            direct_dial = true,
            chevron = true,
        },
    })
end
gate_command.reset_to_idle = function(_instance)
    return result.ok({
        reset_performed = true,
    })
end
gate_state.read = function(_instance)
    return result.ok({
        side = "left",
        interface_type = "advanced_crystal_interface",
        connected = false,
        open = false,
        dialing_out = false,
        idle = true,
        partial_dial = false,
        chevrons_engaged = 0,
        stargate_generation = 2,
        current_symbol = 0,
        energy = {
            stored = 1000,
            capacity = 2000,
            available = true,
        },
        iris = {
            supported = true,
        },
    })
end
rednet_transport.open = function(_side)
    return result.ok(true)
end

local started_gate_controller = gate_controller.start({
    site = "command",
    role = "gate_controller",
    modems = {
        site = "bottom",
    },
})

gate_interface.discover = original_gate_discover
gate_command.reset_to_idle = original_gate_reset_to_idle
gate_state.read = original_gate_state_read
rednet_transport.open = original_transport_open

if not started_gate_controller.ok
    or started_gate_controller.value.startup_reset == nil
    or started_gate_controller.value.startup_reset.reset_performed ~= true
    or started_gate_controller.value.state.idle ~= true
    or started_gate_controller.value.state.activity ~= "idle"
then
    io.stderr:write("Gate controller startup reset failed\n")
    os.exit(1)
end

local original_start_gate_discover = gate_interface.discover
local original_start_gate_reset_to_idle = gate_command.reset_to_idle
local original_start_gate_state_read = gate_state.read
local original_start_transport_open = rednet_transport.open
gate_interface.discover = function()
    return result.ok({
        side = "left",
        interface_type = "advanced_crystal_interface",
        capabilities = {
            disconnect = true,
            stargate_info = true,
            rotation = true,
            state = true,
            iris = true,
            energy = true,
            local_address = true,
            dialed_address = true,
            connected_address = true,
            direct_dial = true,
            chevron = true,
        },
    })
end
gate_command.reset_to_idle = function(_instance)
    return result.err("gate_reset_incomplete", {
        before = {
            connected = true,
            open = false,
            dialing_out = false,
            chevrons_engaged = 0,
        },
        after = {
            connected = true,
            open = false,
            dialing_out = false,
            chevrons_engaged = 0,
        },
    })
end
gate_state.read = function(_instance)
    return result.ok({
        side = "left",
        interface_type = "advanced_crystal_interface",
        connected = true,
        open = false,
        dialing_out = false,
        idle = false,
        partial_dial = false,
        chevrons_engaged = 0,
        activity = "incoming_connected",
        connection_direction = "incoming",
        stargate_generation = 2,
        current_symbol = 0,
        energy = {
            stored = 1000,
            capacity = 2000,
            available = true,
        },
        iris = {
            supported = true,
        },
    })
end
rednet_transport.open = function(_side)
    return result.ok(true)
end

local started_gate_controller_connected = gate_controller.start({
    site = "command",
    role = "gate_controller",
    modems = {
        site = "bottom",
    },
})

gate_interface.discover = original_start_gate_discover
gate_command.reset_to_idle = original_start_gate_reset_to_idle
gate_state.read = original_start_gate_state_read
rednet_transport.open = original_start_transport_open

if not started_gate_controller_connected.ok
    or started_gate_controller_connected.value.startup_reset == nil
    or started_gate_controller_connected.value.startup_reset.blocked ~= true
    or started_gate_controller_connected.value.startup_reset.reason ~= "gate_reset_incomplete"
    or started_gate_controller_connected.value.state.connected ~= true
then
    io.stderr:write("Gate controller startup should tolerate stable connected gate\n")
    os.exit(1)
end

local engaged_symbols = {}
original_peripheral = peripheral
peripheral = {
    call = function(_side, method_name, symbol)
        if method_name == "getChevronsEngaged" then
            return 0
        end

        if method_name == "engageSymbol" then
            engaged_symbols[#engaged_symbols + 1] = symbol
            return 0, "ok"
        end

        if method_name == "getStargateGeneration" then
            return 2
        end

        if method_name == "isStargateConnected" then
            return false
        end

        if method_name == "isStargateDialingOut" then
            return false
        end

        if method_name == "isWormholeOpen" then
            return false
        end

        if method_name == "getEnergy" then
            return 1000
        end

        if method_name == "getEnergyCapacity" then
            return 2000
        end

        if method_name == "getLocalAddress" then
            return { 1, 2, 3, 4, 5, 6, 7, 8 }
        end

        if method_name == "getDialedAddress" then
            return { 9, 11, 14, 21, 22, 29, 0 }
        end

        if method_name == "getConnectedAddress" then
            return nil
        end

        if method_name == "getIris" then
            return "shield"
        end

        if method_name == "getIrisProgress" then
            return 0
        end

        if method_name == "getIrisProgressPercentage" then
            return 0
        end

        error("unexpected method " .. tostring(method_name) .. " symbol=" .. tostring(symbol))
    end,
}

local dial_command = gate_command.execute({
    side = "left",
    interface_type = "advanced_crystal_interface",
    capabilities = {
        energy = true,
        local_address = true,
        dialed_address = true,
        connected_address = true,
        state = true,
        disconnect = true,
        iris = true,
        direct_dial = true,
        stargate_info = true,
        rotation = true,
        chevron = true,
    },
}, {
    action = "dial",
    request_id = "req-3",
    destination_site = sample_destination_site,
    address = { 9, 11, 14, 21, 22, 29 },
    dial_mode = "auto",
})

peripheral = original_peripheral

if not dial_command.ok then
    io.stderr:write("Gate dial execution failed\n")
    os.exit(1)
end

if #engaged_symbols ~= 7 then
    io.stderr:write("Gate dial execution encoded the wrong symbol count\n")
    os.exit(1)
end

if engaged_symbols[1] ~= 9 or engaged_symbols[6] ~= 29 or engaged_symbols[7] ~= 0 then
    io.stderr:write("Gate dial execution encoded unexpected symbols\n")
    os.exit(1)
end

if dial_command.value.dial_mode_used ~= "fast" then
    io.stderr:write("Gate dial execution did not report fast mode\n")
    os.exit(1)
end

local medium_rotations = {}
local medium_open_count = 0
local medium_close_count = 0
original_peripheral = peripheral
peripheral = {
    call = function(_side, method_name, symbol)
        if method_name == "getChevronsEngaged" then
            return 0
        end

        if method_name == "getStargateGeneration" then
            return 2
        end

        if method_name == "isStargateConnected" then
            return false
        end

        if method_name == "isStargateDialingOut" then
            return false
        end

        if method_name == "getCurrentSymbol" then
            return 0
        end

        if method_name == "rotateClockwise" then
            medium_rotations[#medium_rotations + 1] = "clockwise:" .. tostring(symbol)
            return 0, "ok"
        end

        if method_name == "rotateAntiClockwise" then
            medium_rotations[#medium_rotations + 1] = "anti_clockwise:" .. tostring(symbol)
            return 0, "ok"
        end

        if method_name == "isCurrentSymbol" then
            return true
        end

        if method_name == "openChevron" then
            medium_open_count = medium_open_count + 1
            return 0, "ok"
        end

        if method_name == "closeChevron" then
            medium_close_count = medium_close_count + 1
            return 0, "ok"
        end

        if method_name == "isWormholeOpen" then
            return false
        end

        if method_name == "getEnergy" then
            return 1000
        end

        if method_name == "getEnergyCapacity" then
            return 2000
        end

        if method_name == "getLocalAddress" then
            return { 1, 2, 3, 4, 5, 6, 7, 8 }
        end

        if method_name == "getDialedAddress" then
            return { 9, 11, 14, 21, 22, 29, 0 }
        end

        if method_name == "getConnectedAddress" then
            return nil
        end

        if method_name == "getIris" then
            return "shield"
        end

        if method_name == "getIrisProgress" then
            return 0
        end

        if method_name == "getIrisProgressPercentage" then
            return 0
        end

        error("unexpected medium dial method " .. tostring(method_name) .. " symbol=" .. tostring(symbol))
    end,
}

local medium_dial_command = gate_command.execute({
    side = "left",
    interface_type = "basic_interface",
    capabilities = {
        energy = true,
        local_address = false,
        dialed_address = false,
        connected_address = false,
        state = true,
        disconnect = true,
        iris = true,
        direct_dial = false,
        stargate_info = true,
        rotation = true,
        chevron = true,
    },
}, {
    action = "dial",
    request_id = "req-4",
    destination_site = sample_destination_site,
    address = { 38, 1, 35, 34, 3, 5 },
    dial_mode = "auto",
})

peripheral = original_peripheral

if not medium_dial_command.ok then
    io.stderr:write("Medium dial fallback execution failed\n")
    os.exit(1)
end

if #medium_rotations ~= 7 or medium_open_count ~= 7 or medium_close_count ~= 7 then
    io.stderr:write("Medium dial fallback used the wrong rotation or chevron count\n")
    os.exit(1)
end

if medium_rotations[1] ~= "anti_clockwise:38"
    or medium_rotations[2] ~= "clockwise:1"
    or medium_rotations[3] ~= "anti_clockwise:35"
    or medium_rotations[4] ~= "anti_clockwise:34"
    or medium_rotations[5] ~= "clockwise:3"
    or medium_rotations[6] ~= "clockwise:5"
    or medium_rotations[7] ~= "anti_clockwise:0"
then
    io.stderr:write("Medium dial fallback did not choose the fastest rotation path\n")
    os.exit(1)
end

if medium_dial_command.value.dial_mode_used ~= "medium" then
    io.stderr:write("Medium dial fallback did not report medium mode\n")
    os.exit(1)
end

local slow_rotations = {}
local slow_open_count = 0
local slow_close_count = 0
original_peripheral = peripheral
peripheral = {
    call = function(_side, method_name, symbol)
        if method_name == "getChevronsEngaged" then
            return 0
        end

        if method_name == "getStargateGeneration" then
            return 2
        end

        if method_name == "isStargateConnected" then
            return false
        end

        if method_name == "isStargateDialingOut" then
            return false
        end

        if method_name == "rotateClockwise" then
            slow_rotations[#slow_rotations + 1] = "clockwise:" .. tostring(symbol)
            return 0, "ok"
        end

        if method_name == "rotateAntiClockwise" then
            slow_rotations[#slow_rotations + 1] = "anti_clockwise:" .. tostring(symbol)
            return 0, "ok"
        end

        if method_name == "isCurrentSymbol" then
            return true
        end

        if method_name == "openChevron" then
            slow_open_count = slow_open_count + 1
            return 0, "ok"
        end

        if method_name == "closeChevron" then
            slow_close_count = slow_close_count + 1
            return 0, "ok"
        end

        if method_name == "isWormholeOpen" then
            return false
        end

        if method_name == "getEnergy" then
            return 1000
        end

        if method_name == "getEnergyCapacity" then
            return 2000
        end

        if method_name == "getLocalAddress" then
            return { 1, 2, 3, 4, 5, 6, 7, 8 }
        end

        if method_name == "getDialedAddress" then
            return { 9, 11, 14, 21 }
        end

        if method_name == "getConnectedAddress" then
            return nil
        end

        if method_name == "getIris" then
            return "shield"
        end

        if method_name == "getIrisProgress" then
            return 0
        end

        if method_name == "getIrisProgressPercentage" then
            return 0
        end

        error("unexpected slow dial method " .. tostring(method_name) .. " symbol=" .. tostring(symbol))
    end,
}

local slow_dial_command = gate_command.execute({
    side = "left",
    interface_type = "basic_interface",
    capabilities = {
        energy = true,
        local_address = false,
        dialed_address = false,
        connected_address = false,
        state = true,
        disconnect = true,
        iris = true,
        direct_dial = false,
        stargate_info = true,
        rotation = true,
        chevron = true,
    },
}, {
    action = "dial",
    request_id = "req-4b",
    destination_site = sample_destination_site,
    address = { 9, 11, 14, 21, 22, 29 },
    dial_mode = "slow",
})

peripheral = original_peripheral

if not slow_dial_command.ok then
    io.stderr:write("Slow dial execution failed\n")
    os.exit(1)
end

if #slow_rotations ~= 7 or slow_open_count ~= 7 or slow_close_count ~= 7 then
    io.stderr:write("Slow dial used the wrong rotation or chevron count\n")
    os.exit(1)
end

if slow_rotations[1] ~= "clockwise:9"
    or slow_rotations[2] ~= "anti_clockwise:11"
    or slow_rotations[3] ~= "clockwise:14"
    or slow_rotations[4] ~= "anti_clockwise:21"
    or slow_rotations[5] ~= "clockwise:22"
    or slow_rotations[6] ~= "anti_clockwise:29"
    or slow_rotations[7] ~= "clockwise:0"
then
    io.stderr:write("Slow dial did not alternate rotation direction\n")
    os.exit(1)
end

if slow_dial_command.value.dial_mode_used ~= "slow" then
    io.stderr:write("Slow dial did not report slow mode\n")
    os.exit(1)
end

local built_site_request_payload = command_message.build_site_request_payload("command", {
    action = "dial",
    destination_site = sample_destination_site,
    dial_mode = "auto",
})
local validated_site_request_payload = command_message.validate_site_request_payload(built_site_request_payload)
if not validated_site_request_payload.ok then
    io.stderr:write("Command message site request validation failed\n")
    os.exit(1)
end

local built_gate_request_payload = command_message.build_gate_request_payload("command", {
    action = "dial",
    destination_site = sample_destination_site,
    address = { 9, 11, 14, 21, 22, 29, 0 },
    dial_mode = "slow",
})
local validated_gate_request_payload = command_message.validate_gate_request_payload(built_gate_request_payload)
if not validated_gate_request_payload.ok then
    io.stderr:write("Command message gate request validation failed\n")
    os.exit(1)
end

local built_result_payload = command_message.build_result_payload("req-5", result.ok({
    action = "dial",
    dial_mode_used = "fast",
    state = {
        connected = false,
    },
}))
local validated_result_payload = command_message.validate_result_payload(built_result_payload)
if not validated_result_payload.ok then
    io.stderr:write("Command message result validation failed\n")
    os.exit(1)
end

local original_rednet = rednet
local broadcast_capture = nil
local queued_receives = {}
rednet = {
    broadcast = function(message, protocol_name)
        broadcast_capture = {
            message = message,
            protocol = protocol_name,
        }
    end,
    send = function(_receiver_id, _message, _protocol_name)
        return true
    end,
    receive = function(_protocol_filter, _timeout)
        local next_receive = table.remove(queued_receives, 1)
        if next_receive == nil then
            return nil, nil, nil
        end

        return next_receive.sender_id, next_receive.message, next_receive.protocol
    end,
}

local command_config = {
    site = "command",
    role = "dial_console",
    security = {
        allowlist_enabled = false,
        allowed_computer_ids = {},
    },
}
local outbound_command = command_network.broadcast_command(command_config, built_site_request_payload)
if not outbound_command.ok then
    io.stderr:write("Command network broadcast failed\n")
    os.exit(1)
end

if broadcast_capture == nil or broadcast_capture.protocol ~= constants.PROTOCOLS.command then
    io.stderr:write("Command network broadcast used the wrong protocol\n")
    os.exit(1)
end

local inbound_reply = envelope.reply(outbound_command.value, "command", "site_controller", built_result_payload)
if not inbound_reply.ok then
    io.stderr:write("Command network reply envelope creation failed\n")
    os.exit(1)
end

queued_receives[#queued_receives + 1] = {
    sender_id = 42,
    message = inbound_reply.value,
    protocol = constants.PROTOCOLS.command,
}

local waited_result = command_network.wait_for_result(command_config, outbound_command.value.msg_id, 1)
rednet = original_rednet

if not waited_result.ok or waited_result.value.payload.request_id ~= "req-5" then
    io.stderr:write("Command network wait-for-result failed\n")
    os.exit(1)
end

local parsed_transport_message =
    rednet_transport.parse_received_message(command_config, 42, inbound_reply.value, constants.PROTOCOLS.command, nil)
local unexpected_transport_protocol =
    rednet_transport.parse_received_message(command_config, 42, inbound_reply.value, "bad.protocol", nil)
local invalid_transport_body =
    rednet_transport.parse_received_message(command_config, 42, "bad", constants.PROTOCOLS.command, nil)

if not parsed_transport_message.ok
    or parsed_transport_message.value.sender_id ~= 42
    or parsed_transport_message.value.protocol ~= constants.PROTOCOLS.command
    or unexpected_transport_protocol.ok
    or unexpected_transport_protocol.error ~= "unexpected_protocol"
    or invalid_transport_body.ok
    or invalid_transport_body.error ~= "invalid_message_body"
then
    io.stderr:write("Rednet transport message parsing failed\n")
    os.exit(1)
end

do
    rednet = {
        receive = function(_protocol_filter, _timeout)
            if rednet._step == nil then
                rednet._step = 1
                return 13, "bad-body", constants.PROTOCOLS.command
            end

            return 42, inbound_reply.value, constants.PROTOCOLS.command
        end,
    }

    local waited_after_invalid = command_network.wait_for_result(command_config, outbound_command.value.msg_id, 1)
    rednet = original_rednet

    if not waited_after_invalid.ok or waited_after_invalid.value.payload.request_id ~= "req-5" then
        io.stderr:write("Command wait-for-result did not skip invalid inbound traffic\n")
        os.exit(1)
    end
end

local original_transport_receive = rednet_transport.receive
local original_command_broadcast_command = command_network.broadcast_command
local original_command_send_result_reply = command_network.send_result_reply
local original_address_book_send_result = address_book_network.send_result
local nested_address_book_reply = nil
local nested_command_reply = nil
local nested_gate_requests = {}
local queued_site_receives = {}

command_network.broadcast_command = function(_config, payload)
    nested_gate_requests[#nested_gate_requests + 1] = payload
    local message_id = payload.command.action == "status" and "forwarded-status-1" or "forwarded-dial-1"
    return result.ok({
        msg_id = message_id,
    })
end

command_network.send_result_reply = function(_config, receiver_id, request_envelope, payload)
    nested_command_reply = {
        receiver_id = receiver_id,
        request_envelope = request_envelope,
        payload = payload,
    }
    return result.ok(true)
end

address_book_network.send_result = function(_config, receiver_id, request_envelope, payload)
    nested_address_book_reply = {
        receiver_id = receiver_id,
        request_envelope = request_envelope,
        payload = payload,
    }
    return result.ok(true)
end

rednet_transport.receive = function(_config, _timeout, _accepted_protocols)
    local next_receive = table.remove(queued_site_receives, 1)
    if next_receive == nil then
        return result.err("receive_timeout")
    end

    return result.ok(next_receive)
end

local concurrent_book_request = envelope.new(
    "addressbook",
    "command",
    "display",
    address_book_message.build_get_book_request("command", "site_controller", "req-book-during-dial"),
    {
        msg_id = "book-during-dial",
    }
)
if not concurrent_book_request.ok then
    io.stderr:write("Concurrent address book request envelope creation failed\n")
    os.exit(1)
end

local concurrent_gate_reply = envelope.new("result", "command", "gate_controller", command_message.build_result_payload(
    "req-gate-dial",
    result.ok({
        action = "status",
        state = {
            connected = false,
            open = false,
            dialing_out = false,
        },
    })
), {
    msg_id = "gate-status-reply",
    reply_to = "forwarded-status-1",
})
if not concurrent_gate_reply.ok then
    io.stderr:write("Concurrent gate status reply envelope creation failed\n")
    os.exit(1)
end

local concurrent_dial_reply = envelope.new("result", "command", "gate_controller", command_message.build_result_payload(
    "req-gate-dial",
    result.ok({
        action = "dial",
        destination_site = sample_destination_site,
        dial_mode_used = "fast",
        state = {
            connected = false,
            open = false,
            dialing_out = false,
        },
    })
), {
    msg_id = "gate-dial-reply",
    reply_to = "forwarded-dial-1",
})
if not concurrent_dial_reply.ok then
    io.stderr:write("Concurrent gate dial reply envelope creation failed\n")
    os.exit(1)
end

queued_site_receives[#queued_site_receives + 1] = {
    sender_id = 42,
    protocol = constants.PROTOCOLS.command,
    envelope = concurrent_gate_reply.value,
}
queued_site_receives[#queued_site_receives + 1] = {
    sender_id = 41,
    protocol = constants.PROTOCOLS.addressbook,
    envelope = concurrent_book_request.value,
}
queued_site_receives[#queued_site_receives + 1] = {
    sender_id = 43,
    protocol = constants.PROTOCOLS.command,
    envelope = concurrent_dial_reply.value,
}

local concurrent_site_request = envelope.new("command", "command", "dial_console", command_message.build_site_request_payload(
    "command",
    {
        action = "dial",
        request_id = "req-site-dial",
        destination_site = sample_destination_site,
        dial_mode = "auto",
    }
), {
    msg_id = "site-dial-request",
})
if not concurrent_site_request.ok then
    io.stderr:write("Concurrent site command envelope creation failed\n")
    os.exit(1)
end

local concurrent_runtime = {
    state = {
        modems = {
            site = true,
            intersite = true,
        },
    },
    warnings = {},
    address_book = {
        book = validation.value,
    },
    last_command = nil,
}

local concurrent_handled = site_controller.handle_command({
    site = "command",
    role = "site_controller",
    modems = {
        peripheral = nil,
    },
}, concurrent_runtime, {
    sender_id = 10,
    protocol = constants.PROTOCOLS.command,
    envelope = concurrent_site_request.value,
}, nil)

rednet_transport.receive = original_transport_receive
command_network.broadcast_command = original_command_broadcast_command
command_network.send_result_reply = original_command_send_result_reply
address_book_network.send_result = original_address_book_send_result

if not concurrent_handled.ok
    or #nested_gate_requests ~= 2
    or nested_gate_requests[1].command.action ~= "status"
    or nested_gate_requests[2].command.action ~= "dial"
    or nested_address_book_reply == nil
    or nested_address_book_reply.receiver_id ~= 41
    or nested_command_reply == nil
    or nested_command_reply.receiver_id ~= 10
    or nested_command_reply.payload.ok ~= true
    or nested_command_reply.payload.result == nil
    or nested_command_reply.payload.result.destination_site ~= sample_destination_site
then
    io.stderr:write("Site controller did not keep serving while waiting for gate reply\n")
    os.exit(1)
end

local original_transport_receive_wait_queue = rednet_transport.receive
local queued_unrelated_state = net_inbox.new()
local queued_unrelated_envelope = envelope.new(
    "result",
    "command",
    "dial_console",
    command_message.build_result_payload("other-request", result.ok({
        action = "status",
        state = {
            connected = false,
            open = false,
            dialing_out = false,
        },
    })),
    {
        msg_id = "other-reply",
        reply_to = "some-other-request",
    }
)
if not queued_unrelated_envelope.ok then
    io.stderr:write("Queued unrelated envelope creation failed\n")
    os.exit(1)
end

net_inbox.push(queued_unrelated_state, {
    sender_id = 88,
    protocol = constants.PROTOCOLS.command,
    envelope = queued_unrelated_envelope.value,
})

local queued_expected_envelope = envelope.new(
    "result",
    "command",
    "gate_controller",
    command_message.build_result_payload("expected-request", result.ok({
        action = "status",
        state = {
            connected = false,
            open = false,
            dialing_out = false,
        },
    })),
    {
        msg_id = "expected-reply",
        reply_to = "expected-request",
    }
)
if not queued_expected_envelope.ok then
    io.stderr:write("Queued expected envelope creation failed\n")
    os.exit(1)
end

local queued_expected_reply = {
    sender_id = 89,
    protocol = constants.PROTOCOLS.command,
    envelope = queued_expected_envelope.value,
}

rednet_transport.receive = function(_config, _timeout, _accepted_protocols)
    local reply = queued_expected_reply
    queued_expected_reply = nil
    if reply == nil then
        return result.err("receive_timeout")
    end

    return result.ok(reply)
end

local waited_with_queued_unrelated = command_network.wait_for_result({
    site = "command",
    role = "site_controller",
    modems = {
        peripheral = nil,
    },
}, "expected-request", 1, {
    inbox = queued_unrelated_state,
    on_unmatched = function()
        return result.ok(false)
    end,
})

rednet_transport.receive = original_transport_receive_wait_queue

local remaining_unrelated = net_inbox.shift(queued_unrelated_state)
if not waited_with_queued_unrelated.ok
    or waited_with_queued_unrelated.value.envelope.msg_id ~= "expected-reply"
    or remaining_unrelated == nil
    or remaining_unrelated.envelope.msg_id ~= "other-reply"
    or net_inbox.shift(queued_unrelated_state) ~= nil
then
    io.stderr:write("Command wait did not preserve queued unrelated messages while awaiting a reply\n")
    os.exit(1)
end

local before_receive_queued_state = net_inbox.new()
local before_receive_queued_envelope = envelope.new(
    "result",
    "command",
    "site_controller",
    command_message.build_result_payload("before-receive-request", result.ok({
        action = "status",
        state = {
            connected = false,
        },
    })),
    {
        msg_id = "before-receive-reply",
        reply_to = "before-receive-request",
    }
)
if not before_receive_queued_envelope.ok then
    io.stderr:write("Before-receive queued envelope creation failed\n")
    os.exit(1)
end

net_inbox.push(before_receive_queued_state, {
    sender_id = 90,
    protocol = constants.PROTOCOLS.command,
    envelope = before_receive_queued_envelope.value,
})

local before_receive_queued_calls = 0
local waited_before_queued = command_network.wait_for_result({
    site = "command",
    role = "site_controller",
    modems = {
        peripheral = nil,
    },
}, "before-receive-request", 1, {
    inbox = before_receive_queued_state,
    before_receive = function()
        before_receive_queued_calls = before_receive_queued_calls + 1
        return result.ok(false)
    end,
})

if not waited_before_queued.ok
    or waited_before_queued.value.envelope.msg_id ~= "before-receive-reply"
    or before_receive_queued_calls < 1
then
    io.stderr:write("Command wait did not run before-receive hook before queued replies\n")
    os.exit(1)
end

local original_transport_receive_poll = rednet_transport.receive
local poll_expected_envelope = envelope.new(
    "result",
    "command",
    "site_controller",
    command_message.build_result_payload("poll-request", result.ok({
        action = "status",
        state = {
            connected = false,
        },
    })),
    {
        msg_id = "poll-reply",
        reply_to = "poll-request",
    }
)
if not poll_expected_envelope.ok then
    io.stderr:write("Poll interval envelope creation failed\n")
    os.exit(1)
end

local poll_receive_calls = 0
local poll_hook_calls = 0
local poll_timeout_observed = nil
rednet_transport.receive = function(_config, timeout, _accepted_protocols)
    poll_receive_calls = poll_receive_calls + 1
    poll_timeout_observed = timeout
    if poll_receive_calls < 3 then
        return result.err("receive_timeout")
    end

    return result.ok({
        sender_id = 91,
        protocol = constants.PROTOCOLS.command,
        envelope = poll_expected_envelope.value,
    })
end

local waited_with_poll = command_network.wait_for_result({
    site = "command",
    role = "site_controller",
    modems = {
        peripheral = nil,
    },
}, "poll-request", 1, {
    before_receive = function()
        poll_hook_calls = poll_hook_calls + 1
        return result.ok(false)
    end,
    poll_interval_seconds = 0.05,
})

rednet_transport.receive = original_transport_receive_poll

if not waited_with_poll.ok
    or waited_with_poll.value.envelope.msg_id ~= "poll-reply"
    or poll_receive_calls ~= 3
    or poll_hook_calls < 3
    or poll_timeout_observed ~= 0.05
then
    io.stderr:write("Command wait did not poll before-receive hook during long waits\n")
    os.exit(1)
end

local original_transport_receive_retry = rednet_transport.receive
local original_command_broadcast_command_retry = command_network.broadcast_command
local original_command_send_result_reply_retry = command_network.send_result_reply
local probe_then_dial_reply = nil
local probe_then_dial_requests = {}
local probe_then_dial_result = nil

command_network.broadcast_command = function(_config, payload)
    probe_then_dial_requests[#probe_then_dial_requests + 1] = payload.command.action
    local request_number = #probe_then_dial_requests
    if payload.command.action == "status" then
        return result.ok({
            msg_id = "probe-status-" .. tostring(request_number),
        })
    end

    return result.ok({
        msg_id = "probe-dial-1",
    })
end

command_network.send_result_reply = function(_config, receiver_id, request_envelope, payload)
    probe_then_dial_result = {
        receiver_id = receiver_id,
        request_envelope = request_envelope,
        payload = payload,
    }
    return result.ok(true)
end

local probe_then_dial_reply_envelope = envelope.new("result", "command", "gate_controller", command_message.build_result_payload(
    "req-site-dial-after-probe-failure",
    result.ok({
        action = "dial",
        destination_site = sample_destination_site,
        dial_mode_used = "fast",
        state = {
            connected = false,
            open = false,
            dialing_out = true,
        },
    })
), {
    msg_id = "probe-dial-reply",
    reply_to = "probe-dial-1",
})
if not probe_then_dial_reply_envelope.ok then
    io.stderr:write("Probe fallback dial reply envelope creation failed\n")
    os.exit(1)
end
probe_then_dial_reply = {
    sender_id = 44,
    protocol = constants.PROTOCOLS.command,
    envelope = probe_then_dial_reply_envelope.value,
}

rednet_transport.receive = function(_config, _timeout, _accepted_protocols)
    if #probe_then_dial_requests < 4 then
        return result.err("receive_timeout")
    end

    local reply = probe_then_dial_reply
    probe_then_dial_reply = nil
    if reply == nil then
        return result.err("receive_timeout")
    end

    return result.ok(reply)
end

local probe_then_dial_request = envelope.new("command", "command", "dial_console", command_message.build_site_request_payload(
    "command",
    {
        action = "dial",
        request_id = "req-site-dial-after-probe-failure",
        destination_site = sample_destination_site,
        dial_mode = "auto",
    }
), {
    msg_id = "site-dial-after-probe-failure",
})
if not probe_then_dial_request.ok then
    io.stderr:write("Probe fallback site command envelope creation failed\n")
    os.exit(1)
end

local probe_then_dial_runtime = {
    state = {
        modems = {
            site = true,
            intersite = true,
        },
    },
    warnings = {},
    address_book = {
        book = validation.value,
    },
    health = {
        last_internal_error = nil,
        internal_error_count = 0,
        last_internal_error_source = nil,
    },
    last_command = nil,
    gate_contact = {
        last_success_at = nil,
        last_state = nil,
    },
}

local probe_then_dial_handled = site_controller.handle_command({
    site = "command",
    role = "site_controller",
    modems = {
        peripheral = nil,
    },
}, probe_then_dial_runtime, {
    sender_id = 11,
    protocol = constants.PROTOCOLS.command,
    envelope = probe_then_dial_request.value,
}, nil)

rednet_transport.receive = original_transport_receive_retry
command_network.broadcast_command = original_command_broadcast_command_retry
command_network.send_result_reply = original_command_send_result_reply_retry

if not probe_then_dial_handled.ok
    or #probe_then_dial_requests ~= 4
    or probe_then_dial_requests[1] ~= "status"
    or probe_then_dial_requests[2] ~= "status"
    or probe_then_dial_requests[3] ~= "status"
    or probe_then_dial_requests[4] ~= "dial"
    or probe_then_dial_result == nil
    or probe_then_dial_result.payload.ok ~= true
    or probe_then_dial_result.payload.result == nil
    or probe_then_dial_result.payload.result.action ~= "dial"
then
    io.stderr:write("Site controller did not forward dial after failed gate availability probes\n")
    os.exit(1)
end

local built_book_request = address_book_message.build_get_book_request("command", "site_controller", "req-book-1")
local validated_book_request = address_book_message.validate_get_book_request(built_book_request)
if not validated_book_request.ok then
    io.stderr:write("Address book request validation failed\n")
    os.exit(1)
end

if built_book_request.target_role ~= "site_controller" then
    io.stderr:write("Address book request did not preserve site controller target role\n")
    os.exit(1)
end

local built_authoritative_book_request =
    address_book_message.build_get_book_request("command", "address_book", "req-book-2")
if built_authoritative_book_request.target_role ~= "address_book" then
    io.stderr:write("Authoritative address book request used the wrong target role\n")
    os.exit(1)
end

local built_book_result = address_book_message.build_book_result("req-book-1", result.ok(validation.value))
local validated_book_result = address_book_message.validate_book_result(built_book_result)
if not validated_book_result.ok then
    io.stderr:write("Address book result validation failed\n")
    os.exit(1)
end

local built_push_book = address_book_message.build_push_book_payload(validation.value, validation.value.revision, 123456)
local validated_push_book = address_book_message.validate_push_book_payload(built_push_book)
if not validated_push_book.ok
    or validated_push_book.value.book == nil
    or validated_push_book.value.book.revision ~= validation.value.revision
then
    io.stderr:write("Address book push payload validation failed\n")
    os.exit(1)
end

local original_transport_send = rednet_transport.send
local server_reply = nil
rednet_transport.send = function(receiver_id, protocol_name, envelope_message)
    server_reply = {
        receiver_id = receiver_id,
        protocol = protocol_name,
        envelope = envelope_message,
    }
    return result.ok(true)
end

local built_book_request_envelope = envelope.new("addressbook", "command", "site_controller", built_authoritative_book_request)
if not built_book_request_envelope.ok then
    io.stderr:write("Address book request envelope creation failed\n")
    os.exit(1)
end

local handled_server_request = address_book_server.handle_request({
    site = "command",
    role = "address_book",
}, {
    book = validation.value,
}, {
    sender_id = 77,
    protocol = constants.PROTOCOLS.addressbook,
    envelope = built_book_request_envelope.value,
})

rednet_transport.send = original_transport_send

if not handled_server_request.ok
    or server_reply == nil
    or server_reply.protocol ~= constants.PROTOCOLS.addressbook
    or server_reply.envelope.reply_to ~= built_book_request_envelope.value.msg_id
then
    io.stderr:write("Address book server did not handle targeted request\n")
    os.exit(1)
end
end
check_section_8()

local function check_section_10()
do
    local original_address_book_save_cached = address_book_client.save_cached
    local original_transport_broadcast_push = rednet_transport.broadcast
    local pushed_cached_book = nil
    address_book_client.save_cached = function(_config, book)
        pushed_cached_book = book
        return result.ok(true)
    end
    rednet_transport.broadcast = function(_protocol_name, _envelope_message)
        return result.ok(true)
    end

    local pushed_runtime = {
        state = {
            started_at = 12345,
            modems = {
                site = true,
                intersite = true,
            },
        },
        warnings = {},
        address_book = {
            mode = "client",
            availability = "available",
            book = validation.value,
        },
        health = {
            last_internal_error = nil,
            internal_error_count = 0,
            last_internal_error_source = nil,
        },
        last_command = nil,
        gate_contact = {
            last_success_at = nil,
            last_state = nil,
            last_state_sequence = nil,
        },
        site_status_sequence = 0,
        last_published_site_status = nil,
        last_site_status_publish_at = nil,
    }

    local pushed_book = tablex.deep_copy(validation.value)
    pushed_book.revision = pushed_book.revision + 1
    pushed_book.updated_by = "push-tester"

    local pushed_book_envelope = envelope.new(
        "addressbook",
        "command",
        "address_book",
        address_book_message.build_push_book_payload(pushed_book, pushed_book.revision, 123457)
    )
    if not pushed_book_envelope.ok then
        io.stderr:write("Address book push envelope creation failed\n")
        os.exit(1)
    end

    local handled_pushed_book = site_controller.handle_address_book_push({
        site = "command",
        role = "site_controller",
        modems = {
            peripheral = nil,
        },
    }, pushed_runtime, {
        sender_id = 55,
        protocol = constants.PROTOCOLS.addressbook,
        envelope = pushed_book_envelope.value,
    })

    address_book_client.save_cached = original_address_book_save_cached
    rednet_transport.broadcast = original_transport_broadcast_push

    if not handled_pushed_book.ok
        or handled_pushed_book.value == nil
        or handled_pushed_book.value.handled ~= true
        or pushed_cached_book == nil
        or pushed_cached_book.revision ~= pushed_book.revision
        or pushed_runtime.address_book == nil
        or pushed_runtime.address_book.book == nil
        or pushed_runtime.address_book.book.revision ~= pushed_book.revision
        or pushed_runtime.last_published_site_status == nil
        or pushed_runtime.last_published_site_status.address_book_revision ~= pushed_book.revision
    then
        io.stderr:write("Site controller did not apply pushed address book\n")
        os.exit(1)
    end
end

original_rednet = rednet
local original_fs = fs
local original_textutils = textutils
local address_book_broadcast_capture = nil
local address_book_broadcast_protocol = nil
local address_book_receives = {}
local saved_address_book = nil
local serialized_payloads = {}
rednet = {
    isOpen = function()
        return false
    end,
    open = function(_side)
        return true
    end,
    broadcast = function(message, protocol_name)
        address_book_broadcast_capture = {
            message = message,
            protocol = protocol_name,
        }
        address_book_broadcast_protocol = protocol_name
    end,
    send = function(_receiver_id, _message, _protocol_name)
        return true
    end,
    receive = function(_protocol_filter, _timeout)
        local next_receive = table.remove(address_book_receives, 1)
        if next_receive == nil then
            if address_book_broadcast_capture ~= nil and address_book_broadcast_capture.message ~= nil then
                local request_envelope = address_book_broadcast_capture.message
                local request_id = type(request_envelope.payload.request_id) == "string" and request_envelope.payload.request_id
                    or request_envelope.msg_id
                local dynamic_reply = envelope.reply(
                    request_envelope,
                    "command",
                    "address_book_server",
                    address_book_message.build_book_result(request_id, result.ok(validation.value))
                )
                if not dynamic_reply.ok then
                    error("unable to build dynamic address book reply")
                end

                address_book_broadcast_capture = nil
                return 99, dynamic_reply.value, constants.PROTOCOLS.addressbook
            end

            return nil, nil, nil
        end

        return next_receive.sender_id, next_receive.message, next_receive.protocol
    end,
}
fs = {
    exists = function(path)
        return path == "/sgc/cache" or path == "/sgc/tmp"
    end,
    makeDir = function(_path)
    end,
    open = function(path, mode)
        if mode ~= "w" then
            return nil
        end

        local buffer = {}
        return {
            write = function(chunk)
                buffer[#buffer + 1] = chunk
            end,
            close = function()
                if path == "/sgc/cache/address_book.lua" then
                    saved_address_book = table.concat(buffer)
                    return
                end

                if path == constants.DEFAULT_ADDRESS_BOOK_DEBUG_PATH then
                    return
                end

                error("unexpected save path " .. tostring(path))
            end,
        }
    end,
}
textutils = {
    serialize = function(value, _options)
        serialized_payloads[#serialized_payloads + 1] = value
        return tostring(value.schema)
    end,
}

local address_book_client_config = {
    site = "command",
    role = "dial_console",
    modems = {
        site = "bottom",
    },
    address_book = {
        mode = "client",
        cache_path = "/sgc/cache/address_book.lua",
        server_site = "command",
        server_path = "/sgc/data/address_book.json",
    },
    security = {
        allowlist_enabled = false,
        allowed_computer_ids = {},
    },
}

local fetched_book = address_book_client.fetch_remote(address_book_client_config)
rednet = original_rednet
fs = original_fs
textutils = original_textutils

if address_book_broadcast_protocol ~= constants.PROTOCOLS.addressbook then
    io.stderr:write("Address book network used the wrong protocol\n")
    os.exit(1)
end

if not fetched_book.ok or fetched_book.value.revision ~= validation.value.revision or saved_address_book == nil then
    io.stderr:write("Address book remote fetch failed\n")
    os.exit(1)
end

local remote_snapshot = serialized_payloads[#serialized_payloads]
if remote_snapshot == nil
    or remote_snapshot.role ~= "dial_console"
    or remote_snapshot.status ~= "available"
    or remote_snapshot.source ~= "remote"
    or remote_snapshot.book == nil
    or remote_snapshot.book.revision ~= validation.value.revision
then
    io.stderr:write("Address book remote snapshot dump failed\n")
    os.exit(1)
end

local original_client_fetch_remote = address_book_client.fetch_remote
local original_client_load_cached = address_book_client.load_cached
address_book_client.fetch_remote = function(_config)
    return result.ok(validation.value)
end
address_book_client.load_cached = function(_config)
    local stale = address_book.validate(sample.create())
    stale.value.revision = 0
    return stale
end

local remote_preferred_start = address_book_client.start({
    site = "command",
    role = "site_controller",
    modems = {
        site = "bottom",
        intersite = "right",
    },
    address_book = {
        mode = "client",
        cache_path = "/sgc/cache/address_book.lua",
        server_site = "command",
        server_path = "/sgc/data/address_book.json",
    },
})

address_book_client.fetch_remote = original_client_fetch_remote
address_book_client.load_cached = original_client_load_cached

if not remote_preferred_start.ok
    or remote_preferred_start.value.book == nil
    or remote_preferred_start.value.book.revision ~= validation.value.revision
    or remote_preferred_start.value.fetched_remote ~= true
    or remote_preferred_start.value.availability ~= "available"
then
    io.stderr:write("Address book client did not prefer remote snapshot\n")
    os.exit(1)
end
end
check_section_10()

local function check_section_11()
do
    local original_fs_json = fs
    local original_textutils_json = textutils
    local json_payload = nil
    fs = {
        exists = function(path)
            return path == "/sgc/data" or path == "/sgc/data/address_book.json"
        end,
        makeDir = function(_path)
        end,
        open = function(path, mode)
            if path == "/sgc/data/address_book.json" and mode == "w" then
                local buffer = {}
                return {
                    write = function(chunk)
                        buffer[#buffer + 1] = chunk
                    end,
                    close = function()
                        json_payload = table.concat(buffer)
                    end,
                }
            end

            if path == "/sgc/data/address_book.json" and mode == "r" then
                return {
                    readAll = function()
                        return json_payload
                    end,
                    close = function()
                    end,
                }
            end

            return nil
        end,
    }
    textutils = nil

    local saved_json_book = address_book.save("/sgc/data/address_book.json", validation.value)
    local loaded_json_book = address_book.load("/sgc/data/address_book.json")

    fs = original_fs_json
    textutils = original_textutils_json

    if not saved_json_book.ok
        or type(json_payload) ~= "string"
        or json_payload:find('"schema": 2', 1, true) == nil
        or not loaded_json_book.ok
        or loaded_json_book.value.revision ~= validation.value.revision
    then
        io.stderr:write("Address book JSON save/load failed\n")
        os.exit(1)
    end
end
end
check_section_11()

local function check_section_12()
do
    local original_fs_load = fs
    local original_textutils_load = textutils
    fs = {
        exists = function(path)
            return path == "/sgc/cache/address_book.lua"
        end,
        open = function(path, mode)
            if path ~= "/sgc/cache/address_book.lua" or mode ~= "r" then
                return nil
            end

            return {
                readAll = function()
                    return "return legacy-book"
                end,
                close = function()
                end,
            }
        end,
    }
    textutils = {
        unserialize = function(payload)
            if payload == "legacy-book" then
                return validation.value
            end

            return nil
        end,
    }

    local legacy_loaded_book = address_book.load("/sgc/cache/address_book.lua")
    fs = original_fs_load
    textutils = original_textutils_load

    if not legacy_loaded_book.ok or legacy_loaded_book.value.revision ~= validation.value.revision then
        io.stderr:write("Address book legacy serialized load failed\n")
        os.exit(1)
    end
end
end
check_section_12()

local function check_section_13()
do
local server_snapshot = nil
local migrated_json_book = nil
fs = {
    exists = function(path)
        return path == "/sgc/tmp"
    end,
    makeDir = function(_path)
    end,
    open = function(path, mode)
        if mode ~= "w" then
            return nil
        end

        if path ~= constants.DEFAULT_ADDRESS_BOOK_DEBUG_PATH and path ~= "/missing/address_book.json" then
            return nil
        end

        return {
            write = function(_chunk)
            end,
            close = function()
            end,
        }
    end,
}
textutils = {
    serialize = function(value, _options)
        server_snapshot = value
        return tostring(value.schema)
    end,
}

local missing_server_start = address_book_server.start({
    site = "command",
    role = "address_book",
    address_book = {
        server_path = "/missing/address_book.json",
    },
})

if missing_server_start.ok or server_snapshot == nil or server_snapshot.source ~= "server_error" then
    io.stderr:write("Address book server did not fail closed for missing authoritative file\n")
    os.exit(1)
end

server_snapshot = nil
local bootstrap_server_start = address_book_server.start({
    site = "command",
    role = "address_book",
    address_book = {
        server_path = "/missing/address_book.json",
        bootstrap_on_missing = true,
    },
})
local bootstrap_snapshot = server_snapshot

server_snapshot = nil
fs = {
    exists = function(path)
        return path == "/sgc/tmp" or path == "/migrated/address_book.lua"
    end,
    makeDir = function(_path)
    end,
    open = function(path, mode)
        if path == "/migrated/address_book.lua" and mode == "r" then
            return {
                readAll = function()
                    return "return legacy-book"
                end,
                close = function()
                end,
            }
        end

        if mode ~= "w" then
            return nil
        end

        if path == constants.DEFAULT_ADDRESS_BOOK_DEBUG_PATH then
            return {
                write = function(_chunk)
                end,
                close = function()
                end,
            }
        end

        if path == "/migrated/address_book.json" then
            local buffer = {}
            return {
                write = function(chunk)
                    buffer[#buffer + 1] = chunk
                end,
                close = function()
                    migrated_json_book = table.concat(buffer)
                end,
            }
        end

        return nil
    end,
}
textutils = {
    serialize = function(value, _options)
        server_snapshot = value
        return tostring(value.schema)
    end,
    unserialize = function(payload)
        if payload == "legacy-book" then
            return validation.value
        end

        return nil
    end,
}

local migrated_server_start = address_book_server.start({
    site = "command",
    role = "address_book",
    address_book = {
        server_path = "/migrated/address_book.json",
    },
})

fs = original_fs
textutils = original_textutils

if not bootstrap_server_start.ok
    or bootstrap_server_start.value.book == nil
    or bootstrap_snapshot == nil
    or bootstrap_snapshot.role ~= "address_book"
    or bootstrap_snapshot.source ~= "server_bootstrap"
    or bootstrap_snapshot.book == nil
then
    io.stderr:write("Address book server snapshot dump failed\n")
    os.exit(1)
end

if not migrated_server_start.ok
    or migrated_server_start.value.book == nil
    or migrated_server_start.value.book.revision ~= validation.value.revision
    or server_snapshot == nil
    or server_snapshot.source ~= "server_migrated"
    or type(migrated_json_book) ~= "string"
    or migrated_json_book:find('"schema": 2', 1, true) == nil
then
    io.stderr:write("Address book server legacy migration failed\n")
    os.exit(1)
end
end
end
check_section_13()

local function check_remote_monitor_rendering()
    original_peripheral = peripheral
    local original_colors_monitor = colors
    local remote_cursor_x = 1
    local remote_cursor_y = 1
    local remote_monitor_scale = nil
    local remote_monitor_screen = {}
    local remote_monitor_background = nil
    local remote_monitor_foreground = nil
    colors = {
        white = 1,
        orange = 2,
        magenta = 4,
        lightBlue = 8,
        yellow = 16,
        lime = 32,
        pink = 64,
        gray = 128,
        lightGray = 256,
        cyan = 512,
        purple = 1024,
        blue = 2048,
        brown = 4096,
        green = 8192,
        red = 16384,
        black = 32768,
    }

    local function reset_remote_monitor_screen()
        remote_monitor_screen = {}
        for row = 1, 18 do
            remote_monitor_screen[row] = {}
            for column = 1, 39 do
                remote_monitor_screen[row][column] = " "
            end
        end
        remote_cursor_x = 1
        remote_cursor_y = 1
    end

    local function remote_monitor_line(row)
        local line = table.concat(remote_monitor_screen[row] or {})
        return line:gsub("%s+$", "")
    end

    local function find_upvalue(func, wanted_name)
        for index = 1, 64 do
            local upvalue_name, upvalue_value = debug.getupvalue(func, index)
            if upvalue_name == nil then
                return nil
            end
            if upvalue_name == wanted_name then
                return upvalue_value
            end
        end

        return nil
    end

    reset_remote_monitor_screen()
    peripheral = {
        wrap = function(side)
            if side ~= "top" then
                return nil
            end

            return {
                getNamesRemote = function()
                    return { "monitor_0" }
                end,
                hasTypeRemote = function(remote_name, wanted_type)
                    return remote_name == "monitor_0" and wanted_type == "monitor"
                end,
                callRemote = function(remote_name, method_name, ...)
                    if remote_name ~= "monitor_0" then
                        error("unexpected remote peripheral " .. tostring(remote_name))
                    end

                    if method_name == "clear" then
                        reset_remote_monitor_screen()
                        return
                    end

                    if method_name == "setTextScale" then
                        local scale = ...
                        remote_monitor_scale = scale
                        return
                    end

                    if method_name == "getSize" then
                        return 39, 18
                    end

                    if method_name == "setCursorPos" then
                        local x, y = ...
                        remote_cursor_x = x
                        remote_cursor_y = y
                        return
                    end

                    if method_name == "getCursorPos" then
                        return remote_cursor_x, remote_cursor_y
                    end

                    if method_name == "setBackgroundColor" then
                        remote_monitor_background = ...
                        return
                    end

                    if method_name == "setTextColor" then
                        remote_monitor_foreground = ...
                        return
                    end

                    if method_name == "write" then
                        local text = ...
                        for index = 1, #text do
                            local x = remote_cursor_x + index - 1
                            if remote_monitor_screen[remote_cursor_y] ~= nil and remote_monitor_screen[remote_cursor_y][x] ~= nil then
                                remote_monitor_screen[remote_cursor_y][x] = text:sub(index, index)
                            end
                        end
                        remote_cursor_x = remote_cursor_x + #text
                        return
                    end

                    error("unexpected remote monitor method " .. tostring(method_name))
                end,
            }
        end,
    }

    local rendered_remote_monitor = ui_monitor.render("top", {
        "Dial Console",
        "Waiting For Reply",
    }, {
        text_scale = 0.5,
    })
    local rendered_remote_monitor_line_1 = remote_monitor_line(1)
    local opened_remote_monitor = ui_monitor.open("top", {
        text_scale = 0.5,
    })

    if not rendered_remote_monitor.ok
        or rendered_remote_monitor_line_1 ~= "Dial Console"
        or remote_monitor_scale ~= 0.5
        or not opened_remote_monitor.ok
        or opened_remote_monitor.value.id ~= "monitor_0"
        or opened_remote_monitor.value.remote ~= true
    then
        io.stderr:write("Remote monitor rendering failed\n")
        os.exit(1)
    end

    do
        local monitor_runtime = {
            config = config_defaults.for_role("alarm_controller"),
            alarm = config_defaults.for_role("alarm_controller").alarm,
            signals = {
                connection_established = false,
                connection_incoming = false,
                connection_outgoing = false,
                dialing = false,
                connection_disconnected = false,
                traveller_in = false,
                traveller_out = false,
                wormhole_incoming = false,
                wormhole_outgoing = false,
                chevron_engaged = false,
                message_received = false,
                reset = false,
                system_error = true,
            },
            output_state = alarm_output.new_state(),
            monitor = alarm_monitor.new_state(),
            last_gate_fault = "command_timeout",
            last_site_fault = nil,
            last_gate_state = nil,
            last_site_status = nil,
        }
        local rendered_alarm_monitor = alarm_monitor.render(monitor_runtime, 1000)
        local touched_alarm_entry = alarm_monitor.handle_touch(monitor_runtime, "monitor_0", 15, 4, 1000)
        local manual_active = nil
        if touched_alarm_entry ~= nil then
            manual_active = alarm_output.toggle_override(
                monitor_runtime.output_state,
                touched_alarm_entry.binding_key,
                touched_alarm_entry.active == true,
                touched_alarm_entry.natural_active == true
            )
        end
        local snapshot_after_toggle = alarm_output.snapshot(
            monitor_runtime.alarm.outputs,
            monitor_runtime.signals,
            monitor_runtime.output_state,
            1000
        )
        alarm_monitor.note(monitor_runtime.monitor, "right steady system_error manual off", 1000)
        local rerendered_alarm_monitor = alarm_monitor.render(monitor_runtime, 1000)
        local footer_line = remote_monitor_line(18)
        local touched_snapshot = nil

        if snapshot_after_toggle.ok then
            for _, entry in ipairs(snapshot_after_toggle.value) do
                if entry.binding_key == "redstone:right" then
                    touched_snapshot = entry
                    break
                end
            end
        end

        if not rendered_alarm_monitor.ok
            or remote_monitor_line(1):match("^SGC Alarm") == nil
            or remote_monitor_line(2):match("gate fault command_timeout") == nil
            or remote_monitor_line(3):match("left") == nil
            or remote_monitor_line(13):match("patte>") == nil
            or touched_alarm_entry == nil
            or touched_alarm_entry.signal ~= "system_error"
            or touched_alarm_entry.binding_key ~= "redstone:right"
            or manual_active ~= false
            or not snapshot_after_toggle.ok
            or #monitor_runtime.monitor.tiles ~= 12
            or monitor_runtime.monitor.tiles[4] == nil
            or monitor_runtime.monitor.tiles[5] == nil
            or monitor_runtime.monitor.tiles[11] == nil
            or monitor_runtime.monitor.tiles[12] == nil
            or monitor_runtime.monitor.tiles[4].y ~= monitor_runtime.monitor.tiles[1].y
            or monitor_runtime.monitor.tiles[5].y <= monitor_runtime.monitor.tiles[1].y
            or monitor_runtime.monitor.tiles[11].entry.driver ~= "speaker"
            or monitor_runtime.monitor.tiles[11].entry.pattern ~= "pattern_beta"
            or monitor_runtime.monitor.tiles[12].entry.driver ~= "speaker"
            or monitor_runtime.monitor.tiles[12].entry.pattern ~= "pattern_alpha"
            or touched_snapshot == nil
            or touched_snapshot.active ~= false
            or touched_snapshot.natural_active ~= true
            or touched_snapshot.override_active ~= false
            or not rerendered_alarm_monitor.ok
            or footer_line:match("manual off") == nil
            or remote_monitor_background == nil
            or remote_monitor_foreground == nil
        then
            io.stderr:write("Alarm monitor rendering or touch handling failed\n")
            os.exit(1)
        end
    end

    do
        local start_interactive = find_upvalue(dial_console.start, "start_interactive")
        local controller_loop = start_interactive ~= nil and find_upvalue(start_interactive, "controller_loop") or nil
        local render_monitor = controller_loop ~= nil and find_upvalue(controller_loop, "render_monitor") or nil
        local render_home_page = render_monitor ~= nil and find_upvalue(render_monitor, "render_home_page") or nil
        local render_outgoing_page = render_monitor ~= nil and find_upvalue(render_monitor, "render_outgoing_page") or nil
        local update_session_state = controller_loop ~= nil and find_upvalue(controller_loop, "update_session_state") or nil
        local handle_network_message = controller_loop ~= nil and find_upvalue(controller_loop, "handle_network_message") or nil
        local engaged_outgoing_progress = render_monitor ~= nil
                and find_upvalue(render_monitor, "engaged_outgoing_progress")
            or nil
        local outgoing_progress_highlight = render_monitor ~= nil
                and find_upvalue(render_monitor, "outgoing_progress_highlight")
            or nil
        local render_outgoing_address_progress = render_monitor ~= nil
                and find_upvalue(render_monitor, "render_outgoing_address_progress")
            or nil
        local write_monitor_top_bar_line = render_monitor ~= nil
                and find_upvalue(render_monitor, "write_monitor_top_bar_line")
            or nil

        local function render_symbol_colors(engaged_progress, highlight)
            local writes = {}
            local cursor_x = 1
            local cursor_y = 1
            local current_color = colors.white
            local terminal = {
                isColor = function()
                    return true
                end,
                setCursorPos = function(x, y)
                    cursor_x = x
                    cursor_y = y
                end,
                setTextColor = function(color)
                    current_color = color
                end,
                write = function(text)
                    writes[#writes + 1] = {
                        text = text,
                        color = current_color,
                        x = cursor_x,
                        y = cursor_y,
                    }
                    cursor_x = cursor_x + #text
                end,
            }

            render_outgoing_address_progress(
                terminal,
                39,
                5,
                { 9, 11, 14, 21, 22, 29, 0 },
                engaged_progress,
                highlight
            )

            local symbol_colors = {}
            for _, write_call in ipairs(writes) do
                if write_call.text ~= "Address: " and write_call.text ~= "-" and write_call.text:match("%S") ~= nil then
                    symbol_colors[#symbol_colors + 1] = {
                        text = write_call.text,
                        color = write_call.color,
                    }
                end
            end

            return symbol_colors
        end

        local function render_top_bar_chunks(top_bar)
            local writes = {}
            local cursor_x = 1
            local cursor_y = 1
            local current_color = colors.white
            local terminal = {
                isColor = function()
                    return true
                end,
                setCursorPos = function(x, y)
                    cursor_x = x
                    cursor_y = y
                end,
                setTextColor = function(color)
                    current_color = color
                end,
                write = function(text)
                    writes[#writes + 1] = {
                        text = text,
                        color = current_color,
                        x = cursor_x,
                        y = cursor_y,
                    }
                    cursor_x = cursor_x + #text
                end,
            }

            write_monitor_top_bar_line(terminal, 39, 1, top_bar)
            return writes
        end

        local basic_highlight = outgoing_progress_highlight({
            gate_state = {
                interface_type = "basic_interface",
                current_symbol = 11,
            },
        }, { 9, 11, 14, 21, 22, 29, 0 }, 2)
        local basic_symbol_colors = render_symbol_colors(2, basic_highlight)
        local exact_highlight = outgoing_progress_highlight({
            gate_state = {
                interface_type = "advanced_crystal_interface",
                stargate_generation = 2,
                open = false,
                connected = false,
                current_symbol = 14,
            },
            selected_mode = "medium",
        }, { 9, 11, 14, 21, 22, 29, 0 }, 2)
        local exact_symbol_colors = render_symbol_colors(2, exact_highlight)
        local fast_start_runtime = {
            selected_mode = "fast",
            gate_state = {
                interface_type = "advanced_crystal_interface",
                stargate_generation = 2,
                open = false,
                connected = false,
                current_symbol = 0,
                chevrons_engaged = 0,
            },
        }
        local fast_start_engaged = engaged_outgoing_progress(fast_start_runtime, { 9, 11, 14, 21, 22, 29, 0 })
        local fast_start_highlight =
            outgoing_progress_highlight(fast_start_runtime, { 9, 11, 14, 21, 22, 29, 0 }, fast_start_engaged)
        local fast_start_symbol_colors = render_symbol_colors(fast_start_engaged, fast_start_highlight)
        local fast_final_runtime = {
            selected_mode = "fast",
            gate_state = {
                interface_type = "advanced_crystal_interface",
                stargate_generation = 2,
                open = false,
                connected = false,
                current_symbol = 0,
                chevrons_engaged = 6,
            },
        }
        local fast_final_engaged = engaged_outgoing_progress(fast_final_runtime, { 9, 11, 14, 21, 22, 29, 0 })
        local fast_final_highlight =
            outgoing_progress_highlight(fast_final_runtime, { 9, 11, 14, 21, 22, 29, 0 }, fast_final_engaged)
        local fast_final_symbol_colors = render_symbol_colors(fast_final_engaged, fast_final_highlight)
        local auto_final_runtime = {
            selected_mode = "auto",
            gate_state = {
                interface_type = "advanced_crystal_interface",
                stargate_generation = 2,
                open = false,
                connected = false,
                current_symbol = 0,
                chevrons_engaged = 6,
            },
        }
        local auto_final_engaged = engaged_outgoing_progress(auto_final_runtime, { 9, 11, 14, 21, 22, 29, 0 })
        local auto_final_highlight =
            outgoing_progress_highlight(auto_final_runtime, { 9, 11, 14, 21, 22, 29, 0 }, auto_final_engaged)
        local auto_final_symbol_colors = render_symbol_colors(auto_final_engaged, auto_final_highlight)
        local connected_final_runtime = {
            selected_mode = "auto",
            gate_state = {
                interface_type = "advanced_crystal_interface",
                stargate_generation = 2,
                open = true,
                connected = true,
                current_symbol = 0,
                chevrons_engaged = 6,
            },
        }
        local connected_final_engaged =
            engaged_outgoing_progress(connected_final_runtime, { 9, 11, 14, 21, 22, 29, 0 })
        local connected_final_highlight = outgoing_progress_highlight(
            connected_final_runtime,
            { 9, 11, 14, 21, 22, 29, 0 },
            connected_final_engaged
        )
        local connected_final_symbol_colors = render_symbol_colors(connected_final_engaged, connected_final_highlight)
        local dialing_symbol_lines = render_outgoing_page({
            selected_mode = "medium",
            outgoing_session = {
                name = "Dialing Target",
                address = { 9, 11, 14, 21, 22, 29 },
            },
            gate_state = {
                interface_type = "advanced_crystal_interface",
                stargate_generation = 2,
                open = false,
                connected = false,
                current_symbol = 14,
                chevrons_engaged = 2,
                activity = "dialing_out",
            },
        }, 39, 10)
        local symbol_line_found = false
        for _, line in ipairs(dialing_symbol_lines) do
            if line:find("Symbol:", 1, true) ~= nil then
                symbol_line_found = true
                break
            end
        end

        local connected_monitor_writes = {}
        local connected_cursor_x = 1
        local connected_cursor_y = 1
        local connected_color = colors.white
        local connected_terminal = {
            isColor = function()
                return true
            end,
            setCursorPos = function(x, y)
                connected_cursor_x = x
                connected_cursor_y = y
            end,
            setTextColor = function(color)
                connected_color = color
            end,
            write = function(text)
                connected_monitor_writes[#connected_monitor_writes + 1] = {
                    text = text,
                    color = connected_color,
                    x = connected_cursor_x,
                    y = connected_cursor_y,
                }
                connected_cursor_x = connected_cursor_x + #text
            end,
        }
        render_monitor({
            config = {
                site = "command",
                role = "dial_console",
                modems = {
                    peripheral = "top",
                },
            },
            selected_mode = "auto",
            book = validation.value,
            outgoing_session = {
                name = "Connected Target",
                address = { 9, 11, 14, 21, 22, 29 },
            },
            outgoing_connected_at = 1000,
            gate_state = {
                interface_type = "advanced_crystal_interface",
                stargate_generation = 2,
                open = true,
                connected = true,
                connection_direction = "outgoing",
                activity = "outgoing_connected",
                current_symbol = 0,
                chevrons_engaged = 6,
            },
            monitor_session = {
                side = "top",
                text_scale = constants.DEFAULT_MONITOR_TEXT_SCALE,
                terminal = connected_terminal,
                width = 39,
                height = 10,
                id = "monitor_0",
                last_lines = nil,
                last_progress_signature = nil,
            },
            monitor_touch_targets = nil,
            monitor_top_bar = nil,
        })
        local connected_monitor_symbols = {}
        for _, write_call in ipairs(connected_monitor_writes) do
            if write_call.y == 5
                and write_call.text ~= "Address: "
                and write_call.text ~= "-"
                and write_call.text:match("%S") ~= nil
                and write_call.x > #"Address: "
            then
                connected_monitor_symbols[#connected_monitor_symbols + 1] = {
                    text = write_call.text,
                    color = write_call.color,
                }
            end
        end
        local paged_home_runtime = {
            selected_mode = "fast",
            gate_state = {
                interface_type = "basic_interface",
                stargate_generation = 2,
            },
            destinations = {
                { id = "site-1", name = "One" },
                { id = "site-2", name = "Two" },
                { id = "site-3", name = "Three" },
                { id = "site-4", name = "Four" },
                { id = "site-5", name = "Five" },
                { id = "site-6", name = "Six" },
                { id = "site-7", name = "Seven" },
                { id = "site-8", name = "Eight" },
                { id = "site-9", name = "Nine" },
            },
            monitor_touch_targets = nil,
            monitor_top_bar = nil,
        }
        local paged_home_lines = render_home_page(paged_home_runtime, 39, 6)
        local paged_top_bar_chunks = render_top_bar_chunks(paged_home_runtime.monitor_top_bar)
        local tiny_home_runtime = {
            selected_mode = "auto",
            gate_state = nil,
            destinations = {
                { id = "site-1", name = "One" },
            },
            monitor_touch_targets = nil,
            monitor_top_bar = nil,
        }
        local tiny_home_lines = render_home_page(tiny_home_runtime, 3, 1)
        local time_module = require("core.time")
        local original_time_now_ms = time_module.now_ms
        local cancel_session = {
            id = sample_destination_site,
            name = "Cancel Target",
            address = { 9, 11, 14, 21, 22, 29 },
            requested_at = 1000,
        }
        local expired_cancel_runtime = {
            pending_requests = {
                ["dial-1"] = {
                    kind = "dial",
                },
                ["disconnect-1"] = {
                    kind = "disconnect",
                },
            },
            pending_status = nil,
            pending_dial_reply = {
                request_id = "dial-1",
                expires_at = 4000,
            },
            pending_disconnect_reply = {
                request_id = "disconnect-1",
                expires_at = 6000,
            },
            pending_dial = cancel_session,
            cancel_requested = true,
            outgoing_session = cancel_session,
            outgoing_connected_at = nil,
            incoming_session = nil,
            incoming_connected_at = nil,
            gate_state = nil,
            last_gate_state_at = nil,
            last_gate_state_sequence = nil,
            cancelled_session = nil,
            cancelled_until = nil,
            flash_message = nil,
        }
        local command_timeout_cancel_runtime = {
            config = {
                site = "command",
                role = "dial_console",
            },
            pending_requests = {
                ["dial-2"] = {
                    kind = "dial",
                },
                ["disconnect-2"] = {
                    kind = "disconnect",
                },
            },
            pending_status = nil,
            pending_dial_reply = {
                request_id = "dial-2",
                expires_at = 6000,
            },
            pending_disconnect_reply = {
                request_id = "disconnect-2",
                expires_at = 6000,
            },
            pending_dial = cancel_session,
            cancel_requested = true,
            outgoing_session = cancel_session,
            outgoing_connected_at = nil,
            incoming_session = nil,
            incoming_connected_at = nil,
            gate_state = nil,
            last_gate_state_at = nil,
            last_gate_state_sequence = nil,
            cancelled_session = nil,
            cancelled_until = nil,
            flash_message = nil,
        }
        local disconnect_timeout_cancel_runtime = {
            config = {
                site = "command",
                role = "dial_console",
            },
            pending_requests = {
                ["dial-3"] = {
                    kind = "dial",
                },
                ["disconnect-3"] = {
                    kind = "disconnect",
                },
                ["status-3"] = {
                    kind = "gate_status",
                },
            },
            pending_status = {
                request_id = "status-3",
                expires_at = 5000,
            },
            pending_dial_reply = {
                request_id = "dial-3",
                expires_at = 6000,
            },
            pending_disconnect_reply = {
                request_id = "disconnect-3",
                expires_at = 6000,
            },
            pending_dial = cancel_session,
            cancel_requested = true,
            outgoing_session = cancel_session,
            outgoing_connected_at = nil,
            incoming_session = nil,
            incoming_connected_at = nil,
            gate_state = nil,
            last_gate_state_at = nil,
            last_gate_state_sequence = nil,
            cancelled_session = nil,
            cancelled_until = nil,
            flash_message = nil,
        }
        time_module.now_ms = function()
            return 5000
        end
        update_session_state(expired_cancel_runtime)
        handle_network_message(command_timeout_cancel_runtime, {
            sender_id = 42,
            protocol = constants.PROTOCOLS.command,
            envelope = {
                type = "result",
                role = "site_controller",
                site = "command",
                reply_to = "dial-2",
                payload = command_message.build_result_payload("req-dial-2", result.err("command_timeout")),
            },
        })
        handle_network_message(disconnect_timeout_cancel_runtime, {
            sender_id = 42,
            protocol = constants.PROTOCOLS.command,
            envelope = {
                type = "result",
                role = "site_controller",
                site = "command",
                reply_to = "disconnect-3",
                payload = command_message.build_result_payload("req-disconnect-3", result.err("command_timeout")),
            },
        })
        handle_network_message(disconnect_timeout_cancel_runtime, {
            sender_id = 42,
            protocol = constants.PROTOCOLS.command,
            envelope = {
                type = "result",
                role = "site_controller",
                site = "command",
                reply_to = "dial-3",
                payload = command_message.build_result_payload("req-dial-3", result.err("command_timeout")),
            },
        })
        time_module.now_ms = original_time_now_ms
        local expired_cancelled = expired_cancel_runtime.cancel_requested == false
            and expired_cancel_runtime.pending_dial_reply == nil
            and expired_cancel_runtime.pending_disconnect_reply == nil
            and expired_cancel_runtime.pending_requests["dial-1"] == nil
            and expired_cancel_runtime.pending_requests["disconnect-1"] == nil
            and expired_cancel_runtime.cancelled_session == cancel_session
            and expired_cancel_runtime.cancelled_until == 9000
            and expired_cancel_runtime.flash_message ~= nil
            and expired_cancel_runtime.flash_message.text == "Dial cancelled"
        local command_timeout_cancelled = command_timeout_cancel_runtime.cancel_requested == false
            and command_timeout_cancel_runtime.pending_dial_reply == nil
            and command_timeout_cancel_runtime.pending_disconnect_reply == nil
            and command_timeout_cancel_runtime.pending_requests["dial-2"] == nil
            and command_timeout_cancel_runtime.pending_requests["disconnect-2"] == nil
            and command_timeout_cancel_runtime.cancelled_session == cancel_session
            and command_timeout_cancel_runtime.cancelled_until == 9000
            and command_timeout_cancel_runtime.flash_message ~= nil
            and command_timeout_cancel_runtime.flash_message.text == "Dial cancelled"
        local disconnect_timeout_cancelled = disconnect_timeout_cancel_runtime.cancel_requested == false
            and disconnect_timeout_cancel_runtime.pending_dial_reply == nil
            and disconnect_timeout_cancel_runtime.pending_disconnect_reply == nil
            and disconnect_timeout_cancel_runtime.pending_status == nil
            and disconnect_timeout_cancel_runtime.pending_requests["dial-3"] == nil
            and disconnect_timeout_cancel_runtime.pending_requests["disconnect-3"] == nil
            and disconnect_timeout_cancel_runtime.pending_requests["status-3"] == nil
            and disconnect_timeout_cancel_runtime.last_gate_error == nil
            and disconnect_timeout_cancel_runtime.cancelled_session == cancel_session
            and disconnect_timeout_cancel_runtime.cancelled_until == 9000
            and disconnect_timeout_cancel_runtime.flash_message ~= nil
            and disconnect_timeout_cancel_runtime.flash_message.text == "Dial cancelled"

        if start_interactive == nil
            or controller_loop == nil
            or render_monitor == nil
            or render_home_page == nil
            or render_outgoing_page == nil
            or update_session_state == nil
            or handle_network_message == nil
            or engaged_outgoing_progress == nil
            or outgoing_progress_highlight == nil
            or render_outgoing_address_progress == nil
            or write_monitor_top_bar_line == nil
            or not expired_cancelled
            or not command_timeout_cancelled
            or not disconnect_timeout_cancelled
            or basic_highlight == nil
            or basic_highlight.index ~= 3
            or basic_highlight.exact ~= false
            or exact_highlight == nil
            or exact_highlight.index ~= 3
            or exact_highlight.exact ~= true
            or basic_symbol_colors[1] == nil
            or basic_symbol_colors[1].color ~= colors.lime
            or basic_symbol_colors[2] == nil
            or basic_symbol_colors[2].color ~= colors.lime
            or basic_symbol_colors[3] == nil
            or basic_symbol_colors[3].text ~= "14"
            or basic_symbol_colors[3].color ~= colors.orange
            or basic_symbol_colors[4] == nil
            or basic_symbol_colors[4].color ~= colors.gray
            or exact_symbol_colors[3] == nil
            or exact_symbol_colors[3].text ~= "14"
            or exact_symbol_colors[3].color ~= colors.yellow
            or exact_symbol_colors[4] == nil
            or exact_symbol_colors[4].color ~= colors.gray
            or fast_start_engaged ~= 0
            or fast_start_highlight == nil
            or fast_start_highlight.index ~= 1
            or fast_start_highlight.exact ~= false
            or fast_start_symbol_colors[1] == nil
            or fast_start_symbol_colors[1].color ~= colors.orange
            or fast_start_symbol_colors[7] == nil
            or fast_start_symbol_colors[7].color ~= colors.gray
            or fast_final_engaged ~= 6
            or fast_final_highlight ~= nil
            or fast_final_symbol_colors[7] == nil
            or fast_final_symbol_colors[7].text ~= "0"
            or fast_final_symbol_colors[7].color ~= colors.gray
            or auto_final_engaged ~= 6
            or auto_final_highlight ~= nil
            or auto_final_symbol_colors[7] == nil
            or auto_final_symbol_colors[7].text ~= "0"
            or auto_final_symbol_colors[7].color ~= colors.gray
            or connected_final_engaged ~= 7
            or connected_final_highlight ~= nil
            or connected_final_symbol_colors[7] == nil
            or connected_final_symbol_colors[7].text ~= "0"
            or connected_final_symbol_colors[7].color ~= colors.lime
            or symbol_line_found == true
            or connected_monitor_symbols[7] == nil
            or connected_monitor_symbols[7].text ~= "0"
            or connected_monitor_symbols[7].color ~= colors.lime
            or paged_home_runtime.monitor_top_bar == nil
            or paged_home_runtime.monitor_touch_targets == nil
            or paged_home_runtime.monitor_touch_targets.mode == nil
            or paged_home_runtime.monitor_touch_targets.mode.y ~= 1
            or paged_home_runtime.monitor_touch_targets.next_page == nil
            or paged_home_runtime.monitor_touch_targets.next_page.y ~= 1
            or paged_home_runtime.monitor_touch_targets.previous_page ~= nil
            or paged_home_lines[1]:find("Destinations", 1, true) ~= nil
            or paged_home_lines[1]:find("1/2", 1, true) == nil
            or paged_home_lines[1]:find(">", 1, true) == nil
            or paged_top_bar_chunks[2] == nil
            or paged_top_bar_chunks[2].text ~= "FAST"
            or paged_top_bar_chunks[2].color ~= colors.lightGray
            or tiny_home_lines[1] == nil
            or #tiny_home_lines ~= 1
            or tiny_home_runtime.monitor_touch_targets == nil
            or #tiny_home_runtime.monitor_touch_targets.destinations ~= 0
        then
            io.stderr:write("Dial console monitor rendering failed\n")
            os.exit(1)
        end
    end

    peripheral = original_peripheral
    colors = original_colors_monitor

    local original_transport_open = rednet_transport.open
    local original_address_book_client_start = address_book_client.start
    local original_print = print
    rednet_transport.open = function(_side)
        return result.ok(true)
    end
    address_book_client.start = function(_config)
        return result.ok({
            mode = "client",
            cache_loaded = true,
            book = {
                schema = validation.value.schema,
                revision = validation.value.revision,
                updated_at = validation.value.updated_at,
                updated_by = validation.value.updated_by,
                sites = {
                    command = validation.value.sites.command,
                },
            },
        })
    end
    print = function(...)
    end

    local no_destinations_console = dial_console.start({
        site = "command",
        role = "dial_console",
        modems = {
            site = "bottom",
            peripheral = nil,
        },
        address_book = {
            mode = "client",
            cache_path = "/sgc/cache/address_book.lua",
            server_site = "command",
            server_path = "/sgc/data/address_book.json",
        },
    }, nil)

    rednet_transport.open = original_transport_open
    address_book_client.start = original_address_book_client_start
    print = original_print

    if no_destinations_console.ok or no_destinations_console.error ~= "unsupported_environment"
    then
        io.stderr:write("Dial console unsupported environment guard failed\n")
        os.exit(1)
    end
end

check_remote_monitor_rendering()

local function check_section_14()
do
    local manifest = {
        schema = 1,
        channel = "stable",
        source_kind = "workspace",
        revision = "abc123",
        display_version = "B142",
        generated_at = "2026-06-12T00:00:00+00:00",
        managed_paths = {
            "startup.lua",
            "src/",
        },
        files = {
            {
                path = "startup.lua",
                size = 20,
                sha256 = string.rep("a", 64),
            },
            {
                path = "src/main.lua",
                size = 10,
                sha256 = string.rep("b", 64),
            },
        },
    }

    local manifest_validation = update_schema.validate_manifest(manifest)
    if not manifest_validation.ok then
        io.stderr:write("Update manifest validation failed\n")
        os.exit(1)
    end

    local planned_state = update_planner.build_state(manifest)
    local planned_state_validation = update_schema.validate_state(planned_state)
    if not planned_state_validation.ok or planned_state.display_version ~= "B142" then
        io.stderr:write("Update planner state version propagation failed\n")
        os.exit(1)
    end

    local update_plan = update_planner.build_sync_plan(manifest, {
        schema = 1,
        channel = "stable",
        revision = "old_revision",
        managed_paths = {
            "startup.lua",
            "src/",
        },
        files = {
            ["startup.lua"] = {
                size = 20,
                sha256 = string.rep("a", 64),
            },
            ["src/obsolete.lua"] = {
                size = 1,
                sha256 = string.rep("c", 64),
            },
        },
    }, {
        ["startup.lua"] = {
            exists = true,
            size = 20,
        },
        ["src/obsolete.lua"] = {
            exists = true,
            size = 1,
        },
    })

    if not update_plan.ok then
        io.stderr:write("Update sync plan failed\n")
        os.exit(1)
    end

    if #update_plan.value.downloads ~= 1 or update_plan.value.downloads[1].path ~= "src/main.lua" then
        io.stderr:write("Update planner download selection failed\n")
        os.exit(1)
    end

    if #update_plan.value.deletes ~= 1 or update_plan.value.deletes[1] ~= "src/obsolete.lua" then
        io.stderr:write("Update planner delete selection failed\n")
        os.exit(1)
    end
end
end
check_section_14()

print(string.format("Checked %d Lua files", #files))
