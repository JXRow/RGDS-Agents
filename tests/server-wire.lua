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
check("stop script", main:find("engines/stop.sh", 1, true) ~= nil)
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
        "configFile", "setupFile", "statusLine", "statusExit", "adapter",
        "lastStatus", "startPending", "startExit", "startLine", "unhealthySeconds",
    }) do
        check("map " .. field, block:find(field, 1, true) ~= nil)
    end
end

local compile = loadstring or load

local shell = between(main, "local SHELL_THREAD = [[", "]]")
check("shell thread", shell ~= nil)
if shell then
    local compiled, compileErr = compile(shell)
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
    local compiled, compileErr = compile(wizard)
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
check("wizard command", wizardCmd == "/usr/bin/python3 '/app/opencode/opencode-setup-web.py'", wizardCmd)

-- Behavioral check of main.lua wiring with stubbed LÖVE modules.
do
    local channels = {}
    local function channelFor(name)
        if not channels[name] then
            local q = {}
            channels[name] = {
                clear = function() q = {} end,
                push = function(_, v) q[#q + 1] = v end,
                pop = function()
                    if #q == 0 then return nil end
                    return table.remove(q, 1)
                end,
            }
        end
        return channels[name]
    end

    local now = 10
    local startedCmds = {}
    local lastToken = 0
    local clipCount = 0
    local infoCallback = nil
    local savedPaths = {
        configFile = serverstate.paths.configFile,
        setupFile = serverstate.paths.setupFile,
    }

    local tmpCfg = root .. "/.tmp-server-wire-cfg.json"
    local cfgHandle = assert(io.open(tmpCfg, "w"))
    cfgHandle:write('{"model":"provider/model"}\n')
    cfgHandle:close()
    serverstate.paths.configFile = tmpCfg
    serverstate.paths.setupFile = root .. "/.tmp-server-wire-missing-setup.json"

    local savedLoaded = {}
    local function stubMod(name, mod)
        savedLoaded[name] = package.loaded[name]
        package.loaded[name] = mod
    end

    local aidStub = {
        phase = "ready",
        detail = "",
        rev = 0,
        setup = nil,
        start = function() end,
        stop = function() end,
        update = function() end,
        dismiss = function() end,
        hasLog = function() return false end,
        askStatus = function() return true end,
        chat = function() end,
    }
    stubMod("micwave", {
        state = "idle", detail = "", rmsDb = -60, recording = false,
        start = function() end, stop = function() end, update = function() end,
        beginClip = function() clipCount = clipCount + 1; return true end,
        endClip = function() return nil end,
        isLive = function() return false end,
    })
    stubMod("stt", {
        phase = "ready", detail = "", serial = 0, text = "", lang = "",
        start = function() end, stop = function() end, update = function() end,
        transcribe = function() end,
    })
    stubMod("aid", aidStub)
    stubMod("evdev", {
        open = function() return false, "stub" end,
        pump = function() end, close = function() end,
    })
    stubMod("touchpoll", {
        open = function(cb) infoCallback = cb; return true end,
        pump = function() end, close = function() end,
    })
    stubMod("subscreen", {
        open = function() return false, "stub" end,
        close = function() end, present = function() end,
        isOpen = function() return false end,
        display = 0, mainDisplay = 0, frames = 0,
    })
    stubMod("ffi", { cdef = function() error("stub") end })

    local savedLove = _G.love
    local savedPrint = _G.print
    _G.print = function() end
    _G.love = {
        timer = {
            getTime = function() return now end,
            getFPS = function() return 60 end,
            sleep = function() end,
        },
        filesystem = {
            getSource = function() return "/app" end,
            getInfo = function() return nil end,
            write = function() end,
            append = function() end,
        },
        window = {
            getDisplayCount = function() return 1 end,
            isVisible = function() return false end,
            getMode = function() return 640, 480, {display = 1} end,
            setMode = function() return true end,
        },
        graphics = {
            setDefaultFilter = function() end,
            newFont = function()
                return {
                    getHeight = function() return 16 end,
                    getWidth = function() return 10 end,
                    getWrap = function(_, t) return 10, {t} end,
                    setFilter = function() end,
                }
            end,
            getWidth = function() return 640 end,
            getHeight = function() return 480 end,
            getRendererInfo = function() return "stub", "1", "stub", "stub" end,
        },
        math = {setRandomSeed = function() end},
        joystick = {getJoysticks = function() return {} end},
        keyboard = {isDown = function() return false end},
        audio = {newSource = function() return nil end},
        sound = {newSoundData = function() return nil end},
        event = {quit = function() end},
        system = {getOS = function() return "Linux" end},
        getVersion = function() return 11, 5, 0 end,
        thread = {
            getChannel = channelFor,
            newThread = function()
                return {
                    start = function(_, ch, tok, cmd)
                        if type(tok) == "number" then
                            lastToken = tok
                            startedCmds[#startedCmds + 1] = {kind = "shell", ch = ch, tok = tok, cmd = cmd}
                        else
                            startedCmds[#startedCmds + 1] = {kind = "wizard", cmd = ch}
                        end
                        return true
                    end,
                    isRunning = function() return false end,
                    getError = function() return nil end,
                }
            end,
        },
    }

    local loadOk, loadErr = pcall(dofile, root .. "/main.lua")
    check("main.lua loads under stubbed love", loadOk, loadErr)
    if loadOk then
        local okLoad, errLoad = pcall(love.load)
        check("love.load succeeds", okLoad, errLoad)

        -- Pressing 't' while Starting must not crash and must hold chat.
        local pttOk, pttErr = pcall(love.keypressed, "t")
        check("pttPress while starting does not crash", pttOk, pttErr)
        check("pttPress while starting holds chat", clipCount == 0, clipCount)

        -- Bring row to Running, then 't' must start recording.
        aidStub.onEvent({ev = "status", net = "ok", version = "2.4.0"})
        channelFor("rgds-server"):push({token = lastToken, out = "running (pid: 3, health: ok)\n rc=0\n"})
        love.update(0.016)
        local pttRunOk, pttRunErr = pcall(love.keypressed, "t")
        check("pttPress while running does not crash", pttRunOk, pttRunErr)
        check("pttPress while running starts clip", clipCount == 1, clipCount)
        love.keyreleased("t")

        -- Provider auth error must survive status net=ok so WIZARD stays reachable.
        aidStub.onEvent({ev = "error", kind = "auth", msg = "invalid api key"})
        aidStub.onEvent({ev = "status", net = "ok", version = "2.4.0"})
        love.update(0.016)
        local beforeWiz = #startedCmds
        infoCallback(true, 40, 20)
        infoCallback(false, 40, 20)
        check("provider auth keeps wizard action across net=ok",
            #startedCmds == beforeWiz + 1 and startedCmds[#startedCmds].kind == "wizard",
            startedCmds[#startedCmds] and startedCmds[#startedCmds].kind)

        -- Successful turn clears provider auth error back to Running.
        aidStub.onEvent({ev = "done"})
        love.update(0.016)

        -- Password auth error must survive status net=offline.
        aidStub.onEvent({ev = "error", kind = "auth", msg = "HTTP 401 denied"})
        aidStub.onEvent({ev = "status", net = "offline"})
        love.update(0.016)
        local beforeRestart = #startedCmds
        infoCallback(true, 40, 20)
        infoCallback(false, 40, 20)
        check("password auth keeps restart action across net=offline",
            #startedCmds == beforeRestart + 1 and startedCmds[#startedCmds].cmd:find(" restart ", 1, true) ~= nil,
            startedCmds[#startedCmds] and startedCmds[#startedCmds].cmd)

        -- Failed restart clears stale readings and transitions to Failed (action = start).
        channelFor("rgds-server"):push({token = lastToken, out = "!! restart failed\n rc=1\n"})
        love.update(0.016)
        -- Advance past the immediate status probe launched after action completes.
        channelFor("rgds-server"):push({token = lastToken, out = "stopped (pid: none, health: down)\n rc=1\n"})
        love.update(0.016)
        local beforeStart = #startedCmds
        infoCallback(true, 40, 20)
        infoCallback(false, 40, 20)
        check("failed restart exposes start action",
            #startedCmds == beforeStart + 1 and startedCmds[#startedCmds].cmd:find(" start ", 1, true) ~= nil,
            startedCmds[#startedCmds] and startedCmds[#startedCmds].cmd)

        -- Complete that start action so shellJob is idle, then verify SHUTDOWN? blocks touch.
        channelFor("rgds-server"):push({token = lastToken, out = "!! still failed\n rc=1\n"})
        love.update(0.016)
        channelFor("rgds-server"):push({token = lastToken, out = "stopped (pid: none, health: down)\n rc=1\n"})
        love.update(0.016)
        love.joystickpressed(nil, 7) -- opens SHUTDOWN? modal
        local beforeModal = #startedCmds
        infoCallback(true, 40, 20)
        infoCallback(false, 40, 20)
        check("shutdown modal blocks server row touch", #startedCmds == beforeModal, #startedCmds - beforeModal)

        -- Bring back to Running and verify periodic re-probe while running.
        love.joystickpressed(nil, 2) -- close SHUTDOWN? modal
        aidStub.onEvent({ev = "status", net = "ok", version = "2.4.0"})
        now = now + 10
        love.update(0.016)
        channelFor("rgds-server"):push({token = lastToken, out = "running (pid: 3, health: ok)\n rc=0\n"})
        love.update(0.016)
        local runningProbes = #startedCmds
        now = now + 20
        love.update(0.016)
        check("running state still re-probes periodically", #startedCmds == runningProbes + 1, #startedCmds - runningProbes)
    end

    _G.print = savedPrint
    _G.love = savedLove
    for name, mod in pairs(savedLoaded) do package.loaded[name] = mod end
    serverstate.paths.configFile = savedPaths.configFile
    serverstate.paths.setupFile = savedPaths.setupFile
    os.remove(tmpCfg)
end

if failed > 0 then
    io.stderr:write(string.format("server-wire: %d failed, %d checks\n", failed, checks))
    os.exit(1)
end
print(string.format("server-wire: %d ok", checks))
os.exit(0)
