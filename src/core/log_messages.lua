local log_messages = {}

local STARTING_MESSAGE = "< Starting >"
local READY_MESSAGE = "< Ready >"

---@param version string?
---@param site string?
---@return string
function log_messages.startup(version, site)
    if type(version) == "string" and version ~= "" and type(site) == "string" and site ~= "" then
        return version .. " " .. site
    end

    if type(site) == "string" and site ~= "" then
        return site
    end

    if type(version) == "string" and version ~= "" then
        return version
    end

    return "startup"
end

---@return string
function log_messages.starting()
    return STARTING_MESSAGE
end

---@return string
function log_messages.ready()
    return READY_MESSAGE
end

return log_messages
