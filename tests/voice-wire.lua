local src = debug.getinfo(1, "S").source
if src:sub(1, 1) == "@" then src = src:sub(2) end
local here = src:match("^(.*)/") or "."
local root = here:match("^(.*)/tests$") or (here == "tests" and "." or here)
package.path = root .. "/?.lua;" .. package.path

local serverstate = require("serverstate")
local gamepid = require("gamepid")

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

local function shQuote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function readAll(path)
    local handle = assert(io.open(path, "r"))
    local text = handle:read("*a") or ""
    handle:close()
    return text
end

local function writeFile(path, text)
    local handle = assert(io.open(path, "w"))
    handle:write(text)
    handle:close()
end

local function mkTempDir()
    local base = os.getenv("TMPDIR")
    if not base or base == "" then base = root end
    local pipe = io.popen("mktemp -d " .. shQuote(base .. "/.tmp-voice-wire.XXXXXX"))
    local dir = pipe and pipe:read("*l")
    if pipe then pipe:close() end
    if not dir or dir == "" then error("mktemp -d failed") end
    return dir
end

local deploy = readAll(root .. "/deploy.sh")
local hasDeployCopy = false
for line in deploy:gmatch("[^\n]+") do
    if line:match("^%s*rscp%s+") and line:find("voicebutton.lua", 1, true) then
        hasDeployCopy = true
        break
    end
end
check("deploy.sh copies voicebutton.lua", hasDeployCopy)

local tmp = mkTempDir()
local kills = {}

local savedPrint = _G.print
local savedLove = _G.love
local savedLoaded = {}
local savedPidFile = gamepid.PID_FILE
local savedPaths = {
    configFile = serverstate.paths.configFile,
    setupFile = serverstate.paths.setupFile,
}

local function cleanup()
    _G.print = savedPrint
    _G.love = savedLove
    for name, mod in pairs(savedLoaded) do package.loaded[name] = mod end
    gamepid.PID_FILE = savedPidFile
    serverstate.paths.configFile = savedPaths.configFile
    serverstate.paths.setupFile = savedPaths.setupFile
    for i = 1, #kills do
        os.execute("kill " .. kills[i] .. " >/dev/null 2>&1")
    end
    os.execute("rm -rf " .. shQuote(tmp))
end

local function runTest()
    local cfgPath = tmp .. "/opencode.json"
    writeFile(cfgPath, '{"model":"provider/model"}\n')
    serverstate.paths.configFile = cfgPath
    serverstate.paths.setupFile = tmp .. "/missing-setup.json"

    local pidFile = tmp .. "/rgds-game.pid"
    gamepid.PID_FILE = pidFile

    local gameDefault = tmp .. "/game-default"
    local gameL2 = tmp .. "/game-l2"
    local gameNone = tmp .. "/game-none"
    local gameBad = tmp .. "/game-bad"
    local mkStatus = os.execute("mkdir -p "
        .. shQuote(gameDefault) .. " "
        .. shQuote(gameL2) .. " "
        .. shQuote(gameNone) .. " "
        .. shQuote(gameBad))
    assert(mkStatus == true or mkStatus == 0, "mkdir failed")
    writeFile(gameL2 .. "/rgds-voice", "11\n")
    writeFile(gameNone .. "/rgds-voice", "none\n")
    writeFile(gameBad .. "/rgds-voice", "9\n")

    local procPipe = assert(io.popen("RGDS_GAME_ID=love sleep 30 >/dev/null & echo $!"))
    local gamePid = tonumber(procPipe:read("*l"))
    procPipe:close()
    if gamePid then kills[#kills + 1] = gamePid end
    check("spawned tagged game process", type(gamePid) == "number", gamePid)

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
    local lastToken = 0
    local clipBegins = 0
    local clipEnds = 0
    local drawn = {}

    local function stubMod(name, mod)
        savedLoaded[name] = package.loaded[name]
        package.loaded[name] = mod
    end

    local micStub = {
        state = "idle", detail = "", rmsDb = -60, holdDb = -60, gain = 1,
        recording = false, recSeconds = 0, maxClipSeconds = 30,
        start = function() return true end,
        stop = function() end,
        update = function() end,
        drawWave = function() end,
        isLive = function() return true end,
    }
    micStub.beginClip = function()
        clipBegins = clipBegins + 1
        micStub.recording = true
        return true
    end
    micStub.endClip = function()
        clipEnds = clipEnds + 1
        micStub.recording = false
        return nil
    end

    local aidStub = {
        phase = "ready",
        detail = "",
        rev = 0,
        epoch = 0,
        setup = nil,
        log = {},
        start = function() end,
        stop = function() end,
        update = function() end,
        dismiss = function() end,
        hasLog = function() return false end,
        active = function() return false end,
        askStatus = function() return true end,
        chat = function() end,
    }

    stubMod("micwave", micStub)
    stubMod("stt", {
        phase = "ready", detail = "", serial = 0, pending = 0, text = "", lang = "",
        start = function() end, stop = function() end, update = function() end,
        submit = function() end,
    })
    stubMod("aid", aidStub)
    stubMod("evdev", {
        open = function() return false, "stub" end,
        pump = function() end, close = function() end,
    })
    stubMod("touchpoll", {
        open = function() return true end,
        pump = function() end, close = function() end,
    })
    stubMod("subscreen", {
        open = function() return false, "stub" end,
        close = function() end, present = function() end,
        isOpen = function() return false end,
        display = 0, mainDisplay = 0, frames = 0,
    })
    stubMod("ffi", {cdef = function() error("stub") end})

    _G.print = function() end
    _G.love = {
        timer = {
            getTime = function() return now end,
            getFPS = function() return 60 end,
            sleep = function() end,
        },
        filesystem = {
            getSource = function() return root end,
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
                    getWidth = function(_, t) return #(t or "") * 6 end,
                    getWrap = function(_, t) return #(t or "") * 6, {t or ""} end,
                    setFilter = function() end,
                }
            end,
            getWidth = function() return 640 end,
            getHeight = function() return 480 end,
            getRendererInfo = function() return "stub", "1", "stub", "stub" end,
            setColor = function() end,
            setFont = function() end,
            setLineWidth = function() end,
            rectangle = function() end,
            circle = function() end,
            line = function() end,
            push = function() end,
            pop = function() end,
            setScissor = function() end,
            print = function(text) drawn[#drawn + 1] = tostring(text) end,
            printf = function(text) drawn[#drawn + 1] = tostring(text) end,
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
                    start = function(_, _, tok)
                        if type(tok) == "number" then lastToken = tok end
                        return true
                    end,
                    isRunning = function() return false end,
                    getError = function() return nil end,
                }
            end,
        },
    }

    local function captureDraw()
        drawn = {}
        love.draw()
    end

    local function drew(substr)
        for i = 1, #drawn do
            if drawn[i]:find(substr, 1, true) then return true end
        end
        return false
    end

    local function setRunningGame(gamePath)
        writeFile(pidFile, tostring(gamePid) .. "\nlove\n" .. gamePath .. "\n")
        love.update(gamepid.POLL + 0.05)
    end

    local function clearRunningGame()
        os.remove(pidFile)
        love.update(gamepid.POLL + 0.05)
    end

    local function markServerRunning()
        aidStub.onEvent({ev = "status", net = "ok", version = "2.4.0"})
        channelFor("rgds-server"):push({token = lastToken, out = "running (pid: 3, health: ok)\n rc=0\n"})
        love.update(0.016)
    end

    dofile(root .. "/main.lua")
    love.load()

    markServerRunning()

    love.joystickpressed(nil, 11)
    check("no game: L2 does not start clip", clipBegins == 0, clipBegins)
    love.joystickpressed(nil, 6)
    check("no game: R1 starts clip", clipBegins == 1 and micStub.recording, clipBegins)
    love.joystickreleased(nil, 6)
    check("no game: R1 release ends clip", clipEnds == 1 and not micStub.recording, clipEnds)

    setRunningGame(gameDefault)
    captureDraw()
    check("default game: bottom hint shows HOLD R1 TALK", drew("HOLD R1 TALK"))
    love.joystickpressed(nil, 11)
    check("default game: L2 does not start clip", clipBegins == 1, clipBegins)
    love.joystickpressed(nil, 6)
    check("default game: R1 starts clip", clipBegins == 2 and micStub.recording, clipBegins)
    love.joystickreleased(nil, 6)
    check("default game: R1 release ends clip", clipEnds == 2 and not micStub.recording, clipEnds)

    setRunningGame(gameL2)
    captureDraw()
    check("L2 game: bottom hint shows HOLD L2 TALK", drew("HOLD L2 TALK"))
    love.joystickpressed(nil, 6)
    check("L2 game: R1 does not start clip", clipBegins == 2, clipBegins)
    love.joystickpressed(nil, 11)
    check("L2 game: L2 starts clip", clipBegins == 3 and micStub.recording, clipBegins)
    captureDraw()
    check("L2 game: recording label shows release L2 to stop", drew("release L2 to stop"))
    love.joystickreleased(nil, 6)
    check("L2 game: releasing R1 does not end L2 clip", clipEnds == 2 and micStub.recording, clipEnds)
    love.joystickreleased(nil, 11)
    check("L2 game: releasing L2 ends clip", clipEnds == 3 and not micStub.recording, clipEnds)
    love.keypressed("t")
    check("L2 game: key t still starts clip", clipBegins == 4 and micStub.recording, clipBegins)
    love.keyreleased("t")
    check("L2 game: releasing t ends clip", clipEnds == 4 and not micStub.recording, clipEnds)

    setRunningGame(gameNone)
    captureDraw()
    check("none game: bottom hint shows VOICE OFF", drew("VOICE OFF"))
    love.joystickpressed(nil, 6)
    love.joystickpressed(nil, 11)
    love.keypressed("t")
    check("none game: neither R1, L2, nor t starts clip", clipBegins == 4, clipBegins)

    setRunningGame(gameBad)
    captureDraw()
    check("bad voice file: bottom hint shows VOICE FILE BAD", drew("VOICE FILE BAD"))
    love.joystickpressed(nil, 6)
    love.joystickpressed(nil, 9)
    love.joystickpressed(nil, 11)
    love.keypressed("t")
    check("bad voice file: no button or key starts clip", clipBegins == 4, clipBegins)

    setRunningGame(gameL2)
    love.joystickpressed(nil, 11)
    check("mid-hold exit: L2 starts clip", clipBegins == 5 and micStub.recording, clipBegins)
    clearRunningGame()
    love.joystickreleased(nil, 6)
    check("mid-hold exit: releasing R1 does not end L2 clip", clipEnds == 4 and micStub.recording, clipEnds)
    love.joystickreleased(nil, 11)
    check("mid-hold exit: releasing L2 ends clip cleanly", clipEnds == 5 and not micStub.recording, clipEnds)

    love.joystickpressed(nil, 11)
    check("after exit: L2 no longer starts clip", clipBegins == 5, clipBegins)
    love.joystickpressed(nil, 6)
    check("after exit: R1 works again", clipBegins == 6 and micStub.recording, clipBegins)
    love.joystickreleased(nil, 6)
    check("after exit: R1 release ends clip", clipEnds == 6 and not micStub.recording, clipEnds)
end

local ok, err = xpcall(runTest, debug.traceback)
cleanup()
if not ok then
    io.stderr:write("FAIL uncaught: " .. tostring(err) .. "\n")
    os.exit(1)
end
if failed > 0 then
    io.stderr:write(string.format("voice-wire: %d failed, %d checks\n", failed, checks))
    os.exit(1)
end
print(string.format("voice-wire: %d ok", checks))
os.exit(0)
