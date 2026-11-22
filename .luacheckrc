-- luacheck configuration: https://luacheck.readthedocs.io
-- Fibaro HC3 QuickApps run Lua 5.3 with these extra globals.
std = "lua53"
max_line_length = 120

read_globals = {
    "QuickAppChild", "class", "fibaro", "api", "net", "json", "hub", "plugin",
    "setTimeout", "setInterval", "clearTimeout", "clearInterval",
}

-- QuickApp gets this file's methods; class 'PanasonicTempSensor' (QuickAppChild) creates the other
globals = { "QuickApp", "PanasonicTempSensor" }

-- QuickApp methods get "self" whether they use it or not
self = false
