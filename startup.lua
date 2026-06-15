local DEFAULT_CONFIG_PATHS = {
    "/sgc/config.lua",
    "sgc/config.lua",
    "/config.lua",
    "config.lua",
}

local DEFAULT_UPDATE_STATE_PATH = "/sgc/state/update_state.lua"
local DEFAULT_BOOTSTRAP_TEMP_DIR = "/sgc/tmp/bootstrap"
local DEFAULT_BOOTSTRAP_HOST = "127.0.0.1"
local DEFAULT_BOOTSTRAP_PORT = 8090
local DEFAULT_BOOTSTRAP_CHANNEL = "stable"
local CURRENT_ENV = _ENV
local path_exists

local ROLE_ORDER = {
    "site_controller",
    "gate_controller",
    "dial_console",
    "veto_console",
    "display",
    "iris_controller",
    "alarm_controller",
    "energy_controller",
    "address_book",
    "update_client",
    "bridge",
}

local ROLE_SET = {
    site_controller = true,
    gate_controller = true,
    dial_console = true,
    veto_console = true,
    display = true,
    iris_controller = true,
    alarm_controller = true,
    energy_controller = true,
    address_book = true,
    address_book_server = true,
    update_client = true,
    bridge = true,
}

local function ensure_package_system()
    if type(package) ~= "table" then
        package = {}
    end

    if type(package.path) ~= "string" or package.path == "" then
        package.path = "?.lua;?/init.lua"
    end

    if type(package.loaded) ~= "table" then
        package.loaded = {}
    end

    if type(require) == "function" then
        return
    end

    ---@param module_name string
    ---@return string?
    local function resolve_module_path(module_name)
        local normalized_name = module_name:gsub("%.", "/")
        for template in string.gmatch(package.path, "[^;]+") do
            local candidate = template:gsub("%?", normalized_name)
            if path_exists(candidate) then
                return candidate
            end
        end

        return nil
    end

    ---@param module_name string
    ---@return any
    function require(module_name)
        local loaded = package.loaded[module_name]
        if loaded ~= nil then
            return loaded
        end

        local module_path = resolve_module_path(module_name)
        if module_path == nil then
            error("module not found: " .. module_name, 2)
        end

        if type(loadfile) == "function" then
            local module_env = setmetatable({
                require = require,
                package = package,
            }, {
                __index = CURRENT_ENV,
            })

            local chunk, load_error = loadfile(module_path, nil, module_env)
            if chunk == nil then
                error(load_error or ("unable to load module: " .. module_name), 2)
            end

            package.loaded[module_name] = true
            local value = chunk()
            if value == nil then
                value = true
            end
            package.loaded[module_name] = value
            return value
        end

        package.loaded[module_name] = true
        local ok, value = pcall(dofile, module_path)
        if not ok then
            package.loaded[module_name] = nil
            error(value, 2)
        end

        if value == nil then
            value = true
        end
        package.loaded[module_name] = value
        return value
    end
end

---@param path string
---@return any, string?
local function load_module_chunk(path)
    if type(loadfile) == "function" then
        local env = setmetatable({
            require = require,
            package = package,
        }, {
            __index = CURRENT_ENV,
        })

        local chunk, load_error = loadfile(path, nil, env)
        if chunk == nil then
            return nil, load_error
        end

        local ok, value = pcall(chunk)
        if not ok then
            return nil, tostring(value)
        end

        return value, nil
    end

    local ok, value = pcall(dofile, path)
    if not ok then
        return nil, tostring(value)
    end

    return value, nil
end

---@param entry string
local function prepend_package_path(entry)
    if package == nil or type(package.path) ~= "string" then
        return
    end

    if string.find(package.path, entry, 1, true) ~= nil then
        return
    end

    package.path = entry .. ";" .. package.path
end

---@param path string
---@return boolean
function path_exists(path)
    if fs ~= nil and type(fs.exists) == "function" then
        local ok, exists = pcall(fs.exists, path)
        return ok and exists == true
    end

    local handle = io.open(path, "r")
    if handle ~= nil then
        handle:close()
        return true
    end

    return false
end

---@param path string
---@return boolean
local function is_directory(path)
    if fs == nil or type(fs.isDir) ~= "function" then
        return false
    end

    local ok, value = pcall(fs.isDir, path)
    return ok and value == true
end

---@param message string
local function print_error(message)
    if type(printError) == "function" then
        printError("[sgc] " .. message)
    else
        print("[sgc] " .. message)
    end
end

---@param path string
---@return string?
local function dirname(path)
    local normalized = path:gsub("\\", "/")
    return normalized:match("^(.*)/[^/]+$")
end

---@param path string
---@return boolean
local function is_valid_relative_path(path)
    if type(path) ~= "string" or path == "" then
        return false
    end

    if path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil then
        return false
    end

    if path:sub(-1) == "/" then
        return false
    end

    for segment in path:gmatch("[^/]+") do
        if segment == "" or segment == "." or segment == ".." then
            return false
        end
    end

    return true
end

---@param site_id string
---@return boolean
local function is_valid_site_id(site_id)
    return type(site_id) == "string" and site_id:match("^[a-z][a-z0-9_-]*$") ~= nil
end

---@param value any
---@return any
local function deep_copy(value)
    if type(value) ~= "table" then
        return value
    end

    local copy = {}
    for key, nested_value in pairs(value) do
        copy[deep_copy(key)] = deep_copy(nested_value)
    end
    return copy
end

---@param target table
---@param overlay table?
---@return table
local function deep_merge(target, overlay)
    if type(overlay) ~= "table" then
        return target
    end

    for key, value in pairs(overlay) do
        if type(value) == "table" and type(target[key]) == "table" then
            deep_merge(target[key], value)
        else
            target[key] = deep_copy(value)
        end
    end

    return target
end

---@param path string
---@return boolean
local function ensure_parent_dir(path)
    if fs == nil or type(fs.makeDir) ~= "function" then
        return false
    end

    local parent = dirname(path)
    if parent == nil or parent == "" then
        return true
    end

    if path_exists(parent) then
        return is_directory(parent)
    end

    local ok = pcall(fs.makeDir, parent)
    return ok and path_exists(parent)
end

---@param path string
---@return table?, string?
local function load_config_file(path)
    local ok, loaded = pcall(dofile, path)
    if not ok then
        return nil, tostring(loaded)
    end

    if type(loaded) ~= "table" then
        return nil, "config did not return a table"
    end

    return loaded, nil
end

---@param paths string[]
---@return table?, string?, string?
local function load_raw_local_config(paths)
    for _, path in ipairs(paths) do
        if path_exists(path) then
            local loaded, load_error = load_config_file(path)
            return loaded, path, load_error
        end
    end

    return nil, nil, nil
end

---@param prompt string
---@param default_value string?
---@return string
local function read_with_default(prompt, default_value)
    while true do
        if default_value ~= nil and default_value ~= "" then
            write(prompt .. " [" .. default_value .. "]: ")
        else
            write(prompt .. ": ")
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
---@param default_value integer
---@return integer
local function read_integer_with_default(prompt, default_value)
    while true do
        local answer = read_with_default(prompt, tostring(default_value))
        local numeric = tonumber(answer)
        if numeric ~= nil and numeric % 1 == 0 and numeric >= 1 and numeric <= 65535 then
            return numeric
        end
        print("Please enter a whole number between 1 and 65535.")
    end
end

---@param prompt string
---@param default_value boolean
---@return boolean
local function read_yes_no(prompt, default_value)
    local suffix = default_value and " [Y/n]: " or " [y/N]: "

    while true do
        write(prompt .. suffix)
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

---@param default_role string
---@return string
local function read_role(default_role)
    print("Available roles:")
    for _, role in ipairs(ROLE_ORDER) do
        print(" - " .. role)
    end

    while true do
        local role = read_with_default("Role", default_role)
        if ROLE_SET[role] then
            return role
        end
        print("Unsupported role. Choose one of the roles listed above.")
    end
end

---@param payload string
---@return table?, string?
local function decode_json(payload)
    if textutils ~= nil and type(textutils.unserializeJSON) == "function" then
        local ok, decoded = pcall(textutils.unserializeJSON, payload)
        if ok and type(decoded) == "table" then
            return decoded, nil
        end
    end

    if textutils ~= nil and type(textutils.unserialiseJSON) == "function" then
        local ok, decoded = pcall(textutils.unserialiseJSON, payload)
        if ok and type(decoded) == "table" then
            return decoded, nil
        end
    end

    return nil, "JSON decoding is unavailable"
end

---@param url string
---@return string?, string?
local function http_get_text(url)
    if http == nil or type(http.get) ~= "function" then
        return nil, "HTTP is unavailable"
    end

    local ok, response, response_error = pcall(http.get, url, nil, true)
    if not ok then
        return nil, tostring(response)
    end

    if response == nil then
        return nil, tostring(response_error)
    end

    local body = response.readAll()
    response.close()
    if type(body) ~= "string" then
        return nil, "unable to read response body"
    end

    return body, nil
end

---@param raw_url string
---@return string
local function strip_trailing_slashes(raw_url)
    return (raw_url:gsub("/+$", ""))
end

---@param host string
---@param port integer
---@return string
local function build_base_url(host, port)
    return "http://" .. host .. ":" .. tostring(port)
end

---@param base_url string?
---@return string, integer
local function parse_base_url_defaults(base_url)
    if type(base_url) ~= "string" or base_url == "" then
        return DEFAULT_BOOTSTRAP_HOST, DEFAULT_BOOTSTRAP_PORT
    end

    local normalized = strip_trailing_slashes(base_url)
    local host, port_text = normalized:match("^http://([^/:%[]+):(%d+)$")
    if host ~= nil and port_text ~= nil then
        local port = tonumber(port_text)
        if port ~= nil and port % 1 == 0 and port >= 1 and port <= 65535 then
            return host, port
        end
    end

    return DEFAULT_BOOTSTRAP_HOST, DEFAULT_BOOTSTRAP_PORT
end

---@param path string
---@return string
local function url_encode_path(path)
    return (path:gsub("[^%w%-_./]", function(character)
        return string.format("%%%02X", string.byte(character))
    end))
end

---@param path string
---@param content string
---@return boolean, string?
local function write_file(path, content)
    if fs == nil or type(fs.open) ~= "function" then
        return false, "filesystem is unavailable"
    end

    if not ensure_parent_dir(path) then
        return false, "unable to create parent directory for " .. path
    end

    local handle = fs.open(path, "wb")
    if handle == nil then
        return false, "unable to open " .. path .. " for writing"
    end

    handle.write(content)
    handle.close()
    return true, nil
end

---@param path string
---@return boolean, string?
local function delete_path(path)
    if not path_exists(path) then
        return true, nil
    end

    if fs == nil or type(fs.delete) ~= "function" then
        return false, "filesystem delete is unavailable"
    end

    local ok, delete_error = pcall(fs.delete, path)
    if not ok then
        return false, tostring(delete_error)
    end

    return true, nil
end

---@param path string
---@return boolean, string?
local function reset_directory(path)
    local deleted, delete_error = delete_path(path)
    if not deleted then
        return false, delete_error
    end

    if fs == nil or type(fs.makeDir) ~= "function" then
        return false, "filesystem makeDir is unavailable"
    end

    local ok, create_error = pcall(fs.makeDir, path)
    if not ok then
        return false, tostring(create_error)
    end

    return true, nil
end

---@param from_path string
---@param to_path string
---@return boolean, string?
local function move_file(from_path, to_path)
    if fs == nil or type(fs.move) ~= "function" then
        return false, "filesystem move is unavailable"
    end

    if not ensure_parent_dir(to_path) then
        return false, "unable to create parent directory for " .. to_path
    end

    if path_exists(to_path) then
        local deleted, delete_error = delete_path(to_path)
        if not deleted then
            return false, delete_error
        end
    end

    local ok, move_error = pcall(fs.move, from_path, to_path)
    if not ok then
        return false, tostring(move_error)
    end

    return true, nil
end

---@param role string
---@param site string
---@param base_url string
---@param channel string
---@param auto_reboot boolean
---@return table
local function build_default_config(role, site, base_url, channel, auto_reboot)
    local is_address_book_role = role == "address_book" or role == "address_book_server"
    local intersite_side = (role == "site_controller" or is_address_book_role) and "right" or nil
    local site_modem_side = is_address_book_role and nil or "bottom"
    local address_book_mode = "client"

    if role == "gate_controller" or role == "bridge" or role == "update_client" then
        address_book_mode = "disabled"
    elseif is_address_book_role then
        address_book_mode = "server"
    end

    return {
        schema = 2,
        site = site,
        role = role == "address_book_server" and "address_book" or role,
        modems = {
            site = site_modem_side,
            peripheral = "top",
            intersite = intersite_side,
        },
        address_book = {
            mode = address_book_mode,
            cache_path = "/sgc/cache/address_book.lua",
            server_site = site,
            server_path = "/sgc/data/address_book.json",
            bootstrap_on_missing = is_address_book_role,
        },
        security = {
            allowlist_enabled = false,
            allowed_computer_ids = {},
            shared_secret = nil,
        },
        update = {
            mode = "apply",
            base_url = base_url,
            channel = channel,
            state_path = DEFAULT_UPDATE_STATE_PATH,
            temp_dir = "/sgc/tmp/update",
            auto_reboot = auto_reboot,
        },
        logging = {
            level = "info",
        },
        dial_console = {
            monitor_text_scale = 1,
        },
        alarm = {
            poll_interval_ms = 250,
            monitor_text_scale = 0.5,
            trigger_on_fault = true,
            speaker = {
                bindings = {
                    {
                        signal = "system_error",
                        pattern = "pattern_beta",
                    },
                    {
                        signal = "connection_incoming",
                        pattern = "pattern_alpha",
                    },
                },
            },
            outputs = {
                {
                    driver = "redstone",
                    side = "left",
                    signal = "connection_established",
                    active_high = true,
                },
                {
                    driver = "redstone",
                    side = "right",
                    signal = "system_error",
                    active_high = true,
                },
                {
                    driver = "bundled",
                    side = "back",
                    channels = {
                        orange = "connection_established",
                        magenta = {
                            signal = "system_error",
                            mode = "pulse",
                        },
                        blue = "wormhole_incoming",
                        green = "chevron_engaged",
                        red = "wormhole_outgoing",
                        lightBlue = "traveller_in",
                        brown = "traveller_out",
                        gray = "reset",
                    },
                },
            },
        },
    }
end

---@param config_path string
---@param config table
---@return boolean, string?
local function save_config(config_path, config)
    if textutils == nil or type(textutils.serialize) ~= "function" then
        return false, "textutils.serialize is unavailable"
    end

    local content = "return " .. textutils.serialize(config, { compact = false }) .. "\n"
    return write_file(config_path, content)
end

---@param state_path string
---@param manifest table
---@return boolean, string?
local function save_update_state(state_path, manifest)
    if textutils == nil or type(textutils.serialize) ~= "function" then
        return false, "textutils.serialize is unavailable"
    end

    local state_files = {}
    for _, file_record in ipairs(manifest.files) do
        state_files[file_record.path] = {
            size = file_record.size,
            sha256 = file_record.sha256,
        }
    end

    local state = {
        schema = 1,
        channel = manifest.channel,
        revision = manifest.revision,
        managed_paths = manifest.managed_paths,
        files = state_files,
    }
    if type(manifest.display_version) == "string" and manifest.display_version ~= "" then
        state.display_version = manifest.display_version
    end

    local content = "return " .. textutils.serialize(state, { compact = false }) .. "\n"
    return write_file(state_path, content)
end

---@param manifest table
---@return boolean, string?
local function validate_manifest(manifest)
    if type(manifest) ~= "table" then
        return false, "manifest was not an object"
    end

    if type(manifest.channel) ~= "string" or manifest.channel == "" then
        return false, "manifest.channel was missing"
    end

    if type(manifest.files) ~= "table" then
        return false, "manifest.files was missing"
    end

    if type(manifest.managed_paths) ~= "table" then
        return false, "manifest.managed_paths was missing"
    end

    if manifest.display_version ~= nil
        and (type(manifest.display_version) ~= "string" or manifest.display_version == "")
    then
        return false, "manifest.display_version was invalid"
    end

    for _, file_record in ipairs(manifest.files) do
        if type(file_record) ~= "table"
            or type(file_record.path) ~= "string"
            or not is_valid_relative_path(file_record.path)
            or type(file_record.size) ~= "number"
        then
            return false, "manifest contained an invalid file record"
        end
    end

    return true, nil
end

---@param base_url string
---@param channel string
---@return table?, string?
local function fetch_manifest(base_url, channel)
    local manifest_url = strip_trailing_slashes(base_url) .. "/v1/channels/" .. channel .. "/manifest.json"
    local payload, fetch_error = http_get_text(manifest_url)
    if payload == nil then
        return nil, "unable to fetch manifest: " .. tostring(fetch_error)
    end

    local decoded, decode_error = decode_json(payload)
    if decoded == nil then
        return nil, "unable to decode manifest: " .. tostring(decode_error)
    end

    local valid, validation_error = validate_manifest(decoded)
    if not valid then
        return nil, "invalid manifest: " .. tostring(validation_error)
    end

    return decoded, nil
end

---@param base_url string
---@param channel string
---@param file_path string
---@return string?, string?
local function fetch_file(base_url, channel, file_path)
    local file_url = strip_trailing_slashes(base_url)
        .. "/v1/channels/"
        .. channel
        .. "/files/"
        .. url_encode_path(file_path)

    return http_get_text(file_url)
end

---@param left table
---@param right table
---@return boolean
local function compare_file_paths(left, right)
    if left.path == "startup.lua" then
        return false
    end
    if right.path == "startup.lua" then
        return true
    end
    return left.path < right.path
end

---@param temp_dir string
---@param manifest table
---@param base_url string
---@return boolean, string?
local function install_manifest_files(temp_dir, manifest, base_url)
    local prepared, prepare_error = reset_directory(temp_dir)
    if not prepared then
        return false, prepare_error
    end

    table.sort(manifest.files, compare_file_paths)

    for _, file_record in ipairs(manifest.files) do
        local body, fetch_error = fetch_file(base_url, manifest.channel, file_record.path)
        if body == nil then
            return false, "unable to fetch " .. file_record.path .. ": " .. tostring(fetch_error)
        end

        if #body ~= file_record.size then
            return false, "downloaded size mismatch for " .. file_record.path
        end

        local staged_path = fs.combine(temp_dir, file_record.path)
        local written, write_error = write_file(staged_path, body)
        if not written then
            return false, write_error
        end
    end

    for _, file_record in ipairs(manifest.files) do
        local staged_path = fs.combine(temp_dir, file_record.path)
        local moved, move_error = move_file(staged_path, file_record.path)
        if not moved then
            return false, move_error
        end
    end

    delete_path(temp_dir)
    return true, nil
end

---@return boolean
local function bootstrap_prerequisites_ok()
    if fs == nil
        or type(fs.exists) ~= "function"
        or type(fs.isDir) ~= "function"
        or type(fs.open) ~= "function"
        or type(fs.makeDir) ~= "function"
        or type(fs.move) ~= "function"
        or type(fs.delete) ~= "function"
        or type(fs.combine) ~= "function"
    then
        print_error("bootstrap requires ComputerCraft filesystem APIs")
        return false
    end

    if http == nil or type(http.get) ~= "function" then
        print_error("bootstrap requires the HTTP API to be enabled")
        return false
    end

    if textutils == nil or (type(textutils.serialize) ~= "function") then
        print_error("bootstrap requires textutils.serialize")
        return false
    end

    return true
end

---@return boolean
local function run_bootstrap()
    if not bootstrap_prerequisites_ok() then
        return false
    end

    print("[sgc] first-run installer")
    print("[sgc] src/ is missing, so startup.lua will download the runtime from the mirror.")
    print("")

    local existing_config, existing_config_path, config_error = load_raw_local_config(DEFAULT_CONFIG_PATHS)
    if config_error ~= nil then
        print_error("unable to load existing config: " .. config_error)
        return false
    end

    local existing_update = type(existing_config) == "table" and existing_config.update or nil
    local default_host, default_port = parse_base_url_defaults(
        type(existing_update) == "table" and existing_update.base_url or nil
    )
    local mirror_host = read_with_default("Mirror host", default_host)
    local mirror_port = read_integer_with_default("Mirror port", default_port)
    local base_url = build_base_url(mirror_host, mirror_port)

    local channel = read_with_default(
        "Update channel",
        type(existing_update) == "table" and existing_update.channel or DEFAULT_BOOTSTRAP_CHANNEL
    )

    while not is_valid_site_id(channel) do
        print("Channel names use lowercase letters, numbers, underscores, and dashes.")
        channel = read_with_default("Update channel", DEFAULT_BOOTSTRAP_CHANNEL)
    end

    local site = read_with_default("Site id", type(existing_config) == "table" and existing_config.site or "command")
    while not is_valid_site_id(site) do
        print("Site ids must start with a letter and use only lowercase letters, numbers, underscores, and dashes.")
        site = read_with_default("Site id", "command")
    end

    local role = read_role(type(existing_config) == "table" and existing_config.role or "site_controller")
    local auto_reboot_default = true
    if type(existing_update) == "table" and existing_update.auto_reboot ~= nil then
        auto_reboot_default = existing_update.auto_reboot == true
    end

    local auto_reboot = read_yes_no(
        "Automatically reboot after future updates",
        auto_reboot_default
    )

    local config_path = existing_config_path or "config.lua"

    print("")
    print("Bootstrap summary:")
    print(" - config path: " .. config_path)
    print(" - mirror host: " .. mirror_host)
    print(" - mirror port: " .. tostring(mirror_port))
    print(" - mirror url: " .. base_url)
    print(" - channel: " .. channel)
    print(" - site: " .. site)
    print(" - role: " .. role)
    print("")

    if not read_yes_no("Proceed with bootstrap install", true) then
        print("[sgc] bootstrap cancelled")
        return false
    end

    local manifest, manifest_error = fetch_manifest(base_url, channel)
    if manifest == nil then
        print_error(manifest_error)
        return false
    end

    local generated_config = build_default_config(role, site, base_url, channel, auto_reboot)
    local merged_config = deep_merge(generated_config, existing_config)
    merged_config.schema = 2
    merged_config.site = site
    merged_config.role = role
    merged_config.update = merged_config.update or {}
    merged_config.update.mode = "apply"
    merged_config.update.base_url = base_url
    merged_config.update.channel = channel
    merged_config.update.state_path = merged_config.update.state_path or DEFAULT_UPDATE_STATE_PATH
    merged_config.update.temp_dir = merged_config.update.temp_dir or "/sgc/tmp/update"
    merged_config.update.auto_reboot = auto_reboot

    local config_saved, config_save_error = save_config(config_path, merged_config)
    if not config_saved then
        print_error("unable to save config: " .. tostring(config_save_error))
        return false
    end

    local installed, install_error = install_manifest_files(DEFAULT_BOOTSTRAP_TEMP_DIR, manifest, base_url)
    if not installed then
        print_error("unable to install runtime: " .. tostring(install_error))
        return false
    end

    local state_saved, state_save_error = save_update_state(merged_config.update.state_path, manifest)
    if not state_saved then
        print_error("unable to save update state: " .. tostring(state_save_error))
        return false
    end

    print("[sgc] bootstrap install complete")
    return true
end

---@return boolean
local function run_installed_startup()
    ensure_package_system()
    prepend_package_path("src/?/init.lua")
    prepend_package_path("src/?.lua")

    while true do
        local startup_module, load_error = load_module_chunk("src/startup.lua")
        if startup_module ~= nil and type(startup_module) == "table" and type(startup_module.run) == "function" then
            return startup_module.run()
        end

        local failure_message = startup_module ~= nil
            and "boot failed: startup module did not expose run()"
            or "boot failed: " .. tostring(load_error)
        print_error(failure_message)

        if not read_yes_no("Reinstall runtime from mirror", true) then
            return false
        end

        if not run_bootstrap() then
            return false
        end
    end
end

if not path_exists("src/startup.lua") then
    local bootstrapped = run_bootstrap()
    if not bootstrapped then
        return false
    end
end

return run_installed_startup()
