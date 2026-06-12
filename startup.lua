local function prepend_package_path(entry)
    if package == nil or type(package.path) ~= "string" then
        return
    end

    if string.find(package.path, entry, 1, true) ~= nil then
        return
    end

    package.path = entry .. ";" .. package.path
end

prepend_package_path("src/?/init.lua")
prepend_package_path("src/?.lua")

local ok, startup_module = pcall(dofile, "src/startup.lua")
if not ok then
    if type(printError) == "function" then
        printError("[sgc] boot failed: " .. tostring(startup_module))
    else
        print("[sgc] boot failed: " .. tostring(startup_module))
    end
    return false
end

if type(startup_module) == "table" and type(startup_module.run) == "function" then
    return startup_module.run()
end

if type(printError) == "function" then
    printError("[sgc] boot failed: startup module did not expose run()")
else
    print("[sgc] boot failed: startup module did not expose run()")
end

return false
