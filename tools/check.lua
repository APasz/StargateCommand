package.path = "src/?.lua;src/?/init.lua;" .. package.path

local address_book = require("address_book")
local envelope = require("net.envelope")
local sample = require("address_book.sample")
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

if not address_book.can_see(validation.value, "command", "outpost_alpha") then
    io.stderr:write("Visibility check failed for command -> outpost_alpha\n")
    os.exit(1)
end

if address_book.get_best_address(validation.value, "command", "outpost_alpha") == nil then
    io.stderr:write("Address resolution failed for command -> outpost_alpha\n")
    os.exit(1)
end

local hello = envelope.new("hello", "command", "site_controller", {
    probe = true,
})
if not hello.ok then
    io.stderr:write("Envelope creation failed\n")
    os.exit(1)
end

local manifest = {
    schema = 1,
    channel = "stable",
    source_kind = "workspace",
    revision = "abc123",
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

print(string.format("Checked %d Lua files", #files))
