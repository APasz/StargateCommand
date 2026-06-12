local package_tool = {}

local DEPLOY_MANIFEST_PATH = "tools/deploy_manifest.txt"

---@return string[]
local function read_manifest()
    local handle = assert(io.open(DEPLOY_MANIFEST_PATH, "r"))
    local entries = {}

    for line in handle:lines() do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
            entries[#entries + 1] = trimmed
        end
    end

    handle:close()
    return entries
end

---@return string[]
function package_tool.manifest()
    return read_manifest()
end

if ... == nil then
    print("StargateCommand deployment manifest:")
    for _, entry in ipairs(package_tool.manifest()) do
        print(" - " .. entry)
    end
    print("Packaging automation is intentionally deferred for now.")
end

return package_tool
