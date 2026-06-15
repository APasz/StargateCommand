local time = require("core.time")

local log = {}

local LEVELS = {
    debug = 10,
    info = 20,
    warn = 30,
    error = 40,
}

---@param fields table?
---@return string
local function serialize_fields(fields)
    if type(fields) ~= "table" then
        return ""
    end

    if textutils ~= nil and type(textutils.serialize) == "function" then
        return " " .. textutils.serialize(fields, { compact = true })
    end

    return ""
end

---@param component string
---@param min_level string?
function log.new(component, min_level)
    local threshold = LEVELS[min_level or "info"] or LEVELS.info
    local logger = {}

    ---@param level "debug"|"info"|"warn"|"error"
    ---@param message string
    ---@param fields table?
    function logger:log(level, message, fields)
        local weight = LEVELS[level] or LEVELS.info
        if weight < threshold then
            return
        end

        local line = string.format("%s | %s | %s\n%s", time.now_hms(), string.upper(level), component, message)
            .. serialize_fields(fields)

        if level == "error" and type(printError) == "function" then
            printError(line)
            return
        end

        print(line)
    end

    function logger:debug(message, fields)
        self:log("debug", message, fields)
    end

    function logger:info(message, fields)
        self:log("info", message, fields)
    end

    function logger:warn(message, fields)
        self:log("warn", message, fields)
    end

    function logger:error(message, fields)
        self:log("error", message, fields)
    end

    return logger
end

return log
