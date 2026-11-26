-- Wiring of serverstate.lua and targets.lua. No handheld, no port 7788, no port 4096.
--   lua5.1 tests/server-wire.lua

local src = debug.getinfo(1, "S").source
if src:sub(1, 1) == "@" then src = src:sub(2) end
local here = src:match("^(.*)/") or "."
local root = here:match("^(.*)/tests$") or "."
package.path = root .. "/?.lua;" .. package.path

local serverstate = require("serverstate")
local targets = require("targets")

local failed = 0
local checks = 0

local function check(name, cond, extra)
    checks = checks + 1
    if cond then return end
    failed = failed + 1
    io.stderr:write("FAIL " .. name)
    if extra ~= nil then io.stderr:write(" (" .. tostring(extra) .. ")") end
    io.stderr:write("\n")
end

local function read(path)
    local handle = assert(io.open(path, "r"))
    local text = handle:read("*a") or ""
    handle:close()
    return text
end

local main = read(root .. "/main.lua")
local deploy = read(root .. "/deploy.sh")
local aid = read(root .. "/aid.lua")

check("requires serverstate", main:find('require("serverstate")', 1, true) ~= nil)
check("requires targets", main:find('require("targets")', 1, true) ~= nil)
check("no touch info log", main:find("touch: info", 1, true) == nil)
check("no finger mark", main:find("drawFingerMark", 1, true) == nil)
check("no TOUCH label", main:find("TOUCH  ", 1, true) == nil)
check("game stays off", main:find("game = false", 1, true) ~= nil)
check("no stop script", main:find("engines/stop.sh", 1, true) == nil)
check("no server password path", main:find("server.password", 1, true) == nil)
check("chat held", main:find("not serverRow.holdChat", 1, true) ~= nil)
check("ptt held", main:find("serverRow.holdChat then return", 1, true) ~= nil)
check("info finger", main:find("onInfoFinger(phase, x, y)", 1, true) ~= nil)
check("deploy serverstate", deploy:find("serverstate.lua", 1, true) ~= nil)
check("deploy targets", deploy:find("targets.lua", 1, true) ~= nil)
check("aid status op", aid:find('{op = "status"}', 1, true) ~= nil)
check("aid event hook", aid:find("M.onEvent", 1, true) ~= nil)

local function between(text, a, b)
    local i = text:find(a, 1, true)
    if not i then return nil end
    local from = i + #a
    local j = text:find(b, from, true)
    if not j then return nil end
    return text:sub(from, j - 1)
end

local block = between(main, "-- === OpenCode server 行 ===", "-- --shot")
check("server block", block ~= nil)
if block then
    check("block does not print", block:find("print(", 1, true) == nil)
    check("block probes", block:find("probeCommand", 1, true) ~= nil)
    check("block parses", block:find("parseProbe", 1, true) ~= nil)
    check("block maps", block:find("serverstate.map", 1, true) ~= nil)
    check("block steps", block:find("targets.step", 1, true) ~= nil)
    for _, field in ipairs({
        "configPath", "setupPath", "statusLine", "statusExit", "adapter",
        "lastStatus", "startPending", "startExit", "startLine", "unhealthySeconds",
    }) do
        check("map " .. field, block:find(field, 1, true) ~= nil)
    end
end

local shell = between(main, "local SHELL_THREAD = [[", "]]")
check("shell thread", shell ~= nil)
if shell then
    local compiled, compileErr = loadstring(shell)
    check("shell compiles", compiled ~= nil, compileErr)
    check("shell uses popen", shell:find("io.popen", 1, true) ~= nil)
    check("shell discards close", shell:find("pipe:close()", 1, true) ~= nil)
    check("shell does not keep close", shell:find("= pipe:close()", 1, true) == nil)
    check("shell has no 4096", shell:find("4096", 1, true) == nil)
    check("shell has no 7788", shell:find("7788", 1, true) == nil)
end

local wizard = between(main, "local WIZARD_THREAD = [[", "]]")
check("wizard thread", wizard ~= nil)
if wizard then
    local compiled, compileErr = loadstring(wizard)
    check("wizard compiles", compiled ~= nil, compileErr)
    check("wizard detaches", wizard:find("trap '' HUP", 1, true) ~= nil)
    check("wizard does not collect", wizard:find("parseProbe", 1, true) == nil)
    check("wizard discards output", wizard:find("/dev/null", 1, true) ~= nil)
    check("wizard has no 4096", wizard:find("4096", 1, true) == nil)
end

local function lift(action, x, y)
    local list = targets.layout({action = action, game = false})
    local fired, gesture = targets.step(list, nil, true, x, y)
    check(action .. " press", fired == nil)
    fired, gesture = targets.step(list, gesture, false, x, y)
    return fired, list
end

local running = serverstate.map({
    model = "provider/model",
    statusLine = "running (pid: 3, health: ok)",
    statusExit = 0,
    adapter = {ev = "status", net = "ok", version = "2.4.0"},
    phase = "ready",
})
check("running action", running.action == "restart", running.action)
check("running word", running.word == "Running")
local fired, list = lift(running.action, 40, 20)
check("lift fires restart", fired and fired.op == "restart" and fired.id == "action")
check("one target", #list == 1)
local outside = targets.step(list, {down = true}, false, 40, 100)
check("chat is not a target", outside == nil)

local missing = serverstate.map({configText = "{}"})
check("wizard action", missing.action == "wizard", missing.action)
fired, list = lift(missing.action, 30, 16)
check("lift fires wizard", fired and fired.op == "wizard" and fired.label == "WIZARD")
check("stop absent", list[2] == nil)

local stopped = serverstate.map({
    model = "provider/model",
    statusLine = "stopped (pid: none, health: down)",
    statusExit = 1,
})
check("start action", stopped.action == "start", stopped.action)
fired = lift(stopped.action, 600, 40)
check("right end is the action", fired and fired.op == "start")

local probe = serverstate.probeCommand("/app/opencode/opencode-service.sh")
check("probe quotes the script", probe:find("'/app/opencode/opencode-service.sh' status", 1, true) == 1)
check("probe records rc", probe:find('echo " rc=$?"', 1, true) ~= nil)
local startCmd = serverstate.actionCommand("start", "/app/opencode/opencode-service.sh")
check("start command", startCmd:find(" start 2>&1", 1, true) ~= nil)
local wizardCmd = serverstate.actionCommand("wizard", nil, "/app/opencode/opencode-setup-web.py")
check("wizard command", wizardCmd == "'/app/opencode/opencode-setup-web.py'", wizardCmd)

if failed > 0 then
    io.stderr:write(string.format("server-wire: %d failed, %d checks\n", failed, checks))
    os.exit(1)
end
print(string.format("server-wire: %d ok", checks))
os.exit(0)
