-- lua5.1 tests/gamepid-test.lua
-- Pid file, top-panel state, pad, and STOP GAME. No LÖVE, no handheld, no ports.

local src = debug.getinfo(1, "S").source
if src:sub(1, 1) == "@" then src = src:sub(2) end
local here = src:match("^(.*)/") or "."
local root = here:match("^(.*)/tests$") or (here == "tests" and "." or here)
package.path = root .. "/?.lua;" .. package.path

local gamepid = require("gamepid")
local engines = require("engines")

local failures = 0
local checks = 0

local function check(cond, msg)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        io.stderr:write("FAIL: " .. msg .. "\n")
    end
end

local function shQuote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local pipe = io.popen("mktemp -d")
local tmp = pipe:read("*l")
pipe:close()
if not tmp or tmp == "" then
    io.stderr:write("FAIL: mktemp\n")
    os.exit(1)
end

local kills = {}

local function cleanup()
    for i = 1, #kills do
        os.execute("kill " .. kills[i] .. " >/dev/null 2>&1")
    end
    os.execute("rm -rf " .. shQuote(tmp))
end

local function done(code)
    cleanup()
    os.exit(code)
end

local function writeFile(path, text)
    local handle = io.open(path, "w")
    if not handle then return false end
    handle:write(text)
    handle:close()
    return true
end

local function spawnSleep()
    local handle = io.popen("sleep 30 >/dev/null & echo $!")
    local pid = handle and tonumber(handle:read("*l"))
    if handle then handle:close() end
    if pid then kills[#kills + 1] = pid end
    return pid
end

local function spawnTagged(id)
    local handle = io.popen("RGDS_GAME_ID=" .. tostring(id) .. " sleep 30 >/dev/null & echo $!")
    local pid = handle and tonumber(handle:read("*l"))
    if handle then handle:close() end
    if pid then kills[#kills + 1] = pid end
    return pid
end

local function waitResult(dir, secret)
    for _ = 1, 40 do
        local result = gamepid.finish(dir, secret)
        if result then return result end
        os.execute("sleep 0.05")
    end
    return nil
end

check(gamepid.POLL > 0 and gamepid.POLL <= 0.25, "poll at least four times a second")

local missing = tmp .. "/no-such-pid"
check(gamepid.read(missing) == nil, "missing pid file")
check(gamepid.read(tmp) == nil, "a directory is not a pid file")

local empty = tmp .. "/empty.pid"
writeFile(empty, "")
check(gamepid.read(empty) == nil, "empty pid file")

local garbage = tmp .. "/garbage.pid"
writeFile(garbage, "nope\nlove\n/game\n")
check(gamepid.read(garbage) == nil, "garbage pid file")

writeFile(garbage, "0\nlove\n/game\n")
check(gamepid.read(garbage) == nil, "pid 0")

local selfFile = io.open("/proc/self/stat", "r")
local selfText = selfFile:read("*a")
selfFile:close()
local selfPid = tonumber(selfText:match("^(%d+)"))
check(type(selfPid) == "number" and gamepid.alive(selfPid), "this process is alive")

local tagged = spawnTagged("love")
check(type(tagged) == "number", "spawned a tagged game")
local livePath = tmp .. "/live.pid"
local liveGame = "/work/demo.love"
local live
if tagged then
    writeFile(livePath, tagged .. "\nlove\n" .. liveGame .. "\n")
    live = gamepid.read(livePath)
    check(type(live) == "table", "live pid file")
    if live then
        check(live.pid == tagged, "live pid number")
        check(live.id == "love", "live engine id")
        check(live.path == liveGame, "live game path")
        check(live.alive == true, "tagged pid is our game")
    end
    writeFile(livePath, tagged .. "\nopenbor\n" .. liveGame .. "\n")
    local wrong = gamepid.read(livePath)
    check(wrong and wrong.alive == false, "a different engine id is not our game")
    writeFile(livePath, tagged .. "\n\n" .. liveGame .. "\n")
    local blankId = gamepid.read(livePath)
    check(blankId and blankId.alive == false, "a live pid with no engine id is not our game")
    writeFile(livePath, tagged .. "\nlove\n" .. liveGame .. "\n")
    live = gamepid.read(livePath)
end

local sleeper = spawnSleep()
check(type(sleeper) == "number", "spawned a sleeper")
local sleeperPath = tmp .. "/sleeper.pid"
if sleeper then
    writeFile(sleeperPath, tostring(sleeper) .. "\r\nopenbor\r\n/work/bor.pak\r\n")
    local running = gamepid.read(sleeperPath)
    check(running and running.alive == false and running.id == "openbor",
        "an unrelated live pid is not the game")
    check(gamepid.alive(sleeper), "the unrelated process is still alive")
    check(running and running.path == "/work/bor.pak", "cr is stripped from the path")
    os.execute("kill " .. sleeper .. " >/dev/null 2>&1")
    for _ = 1, 20 do
        if not gamepid.alive(sleeper) then break end
        os.execute("sleep 0.05")
    end
    local dead = gamepid.read(sleeperPath)
    check(type(dead) == "table" and dead.alive == false, "dead pid stays in the file and is not alive")
    check(dead and dead.pid == sleeper, "dead pid number is kept")
end

local state, effect = gamepid.observe(gamepid.blank(), nil)
check(state.phase == "finder" and effect == nil and state.game == nil, "no file stays on the finder")

state, effect = gamepid.observe(gamepid.blank(), {pid = 1, id = "love", path = liveGame, alive = false})
check(state.phase == "finder" and effect == nil, "a dead pid does not close the finder")

local loveLabel
for i = 1, #engines.list do
    if engines.list[i].id == "love" then loveLabel = engines.list[i].label end
end
state, effect = gamepid.observe(gamepid.blank(), live)
check(effect == "close" and state.phase == "running", "a live pid closes the finder")
check(state.notice == nil, "a live pid clears a failure")
check(state.game and state.game.name == "demo.love", "game name is the path tail")
check(state.game and state.game.label == loveLabel, "game label comes from the engine table")
check(gamepid.runningHint(state) == loveLabel .. "  ·  demo.love  ·  HOLD R1 TALK",
    "running hint is the engine, the game, and R1")

local again, againEffect = gamepid.observe(state, live)
check(again.phase == "running" and againEffect == nil, "a second reading does not close again")

local failedHold = gamepid.fail(state, "engine exited", false)
check(failedHold.phase == "running", "a failure while the pid is alive keeps the game")
local opened, openEffect = gamepid.observe(failedHold, {alive = false})
check(openEffect == "open" and opened.phase == "failed" and opened.game == nil,
    "a dead pid reopens the finder and keeps the failure")

local left, leftEffect = gamepid.observe(state, nil)
check(leftEffect == "open" and left.phase == "finder" and left.game == nil,
    "a missing pid file reopens the finder")

local secret = "pw-sample-not-real"
local long = string.rep("x", 200)
local clipped = gamepid.clip(long, false)
check(#clipped == 180, "a failure line is cut at 180, got " .. #clipped)
local marked = gamepid.clip("boom " .. secret .. " tail", secret)
check(not marked:find(secret, 1, true), "a failure line does not keep the secret")
check(marked == "boom [redacted] tail", "the secret is replaced")
local both = gamepid.clip(secret .. " and " .. secret, secret)
check(not both:find(secret, 1, true), "every copy of the secret is replaced")
local split = gamepid.clip(string.rep("a", 179) .. string.char(0xC3, 0xA9), false)
check(split == string.rep("a", 179), "a cut does not leave a partial character")

local noticed = gamepid.fail(gamepid.blank(), "  " .. secret .. "  \n", secret)
check(noticed.phase == "failed", "a failed start stays on the finder")
check(noticed.notice == "[redacted]", "the finder failure is redacted")
check(not noticed.notice:find(secret, 1, true), "the stored notice has no secret")
local cleared = gamepid.clearNotice(noticed)
check(cleared.phase == "finder" and cleared.notice == nil, "clearing a failure returns to the finder")
check(gamepid.fail(gamepid.blank(), "   \n", false).notice == gamepid.FAIL_LINE,
    "an empty failure line has a short fallback")

local pwPath = tmp .. "/password"
writeFile(pwPath, secret .. "\n")
local readPw = gamepid.readSecret(pwPath)
check(readPw == secret, "the password file is its first line")
check(gamepid.readSecret(tmp .. "/no-password") == nil, "a missing password file is nil")

local function writeScript(name, body)
    local path = tmp .. "/" .. name
    writeFile(path, body)
    os.execute("chmod +x " .. shQuote(path))
    return path
end

local marker = tmp .. "/marker"
local tricky = tmp .. "/o'hare game"
local failScript = writeScript("fail.sh", "#!/bin/sh\nprintf '%s\\n' \"$1\" > " .. shQuote(marker) .. "\nprintf '%s\\n' 'saw " .. secret .. "' >&2\nexit 1\n")
local startDir = tmp .. "/start-result"
check(gamepid.begin(failScript, tricky, startDir), "a start script is launched")
local failedRun = waitResult(startDir, secret)
check(type(failedRun) == "table" and failedRun.ok == false, "a start that exits 1 is a failure")
if failedRun then
    check(not failedRun.notice:find(secret, 1, true), "the script failure does not return the secret")
    check(failedRun.notice == "saw [redacted]", "the script line is redacted")
end
local markedText = ""
local markerFile = io.open(marker, "r")
if markerFile then
    markedText = markerFile:read("*l") or ""
    markerFile:close()
end
check(markedText == tricky, "the start script receives the game path")
check(io.open(startDir .. "/err", "r") == nil, "the script's stderr is not left behind")
check(io.open(startDir .. "/out", "r") == nil, "the script's stdout is not left behind")
check(gamepid.finish(startDir, false) == nil, "a start result is consumed once")

local okScript = writeScript("ok.sh", "#!/bin/sh\nprintf '%s\\n' 5150\nexit 0\n")
local okDir = tmp .. "/ok-result"
check(gamepid.begin(okScript, nil, okDir), "a script with no extra argument is launched")
local okRun = waitResult(okDir, false)
check(okRun and okRun.ok == true and okRun.pid == 5150, "a successful script returns the pid it printed")

local stopFake = writeScript("stop.sh", "#!/bin/sh\nif [ \"$#\" -ne 0 ]; then exit 3; fi\nprintf '%s\\n' stopped\nexit 0\n")
local stopDir = tmp .. "/stop-result"
check(gamepid.begin(stopFake, nil, stopDir), "stop is launched with no path")
local stopRun = waitResult(stopDir, false)
check(stopRun and stopRun.ok == true, "stop with no arguments exits 0")

check(type(engines.stop) == "string" and engines.stop:match("/engines/stop%.sh$") ~= nil,
    "the shared stop script is engines/stop.sh")
local stopFile = io.open(engines.stop, "r")
check(stopFile ~= nil, "engines/stop.sh is in the tree")
if stopFile then stopFile:close() end

local loveDir = tmp .. "/lovegame"
local borDir = tmp .. "/bor"
os.execute("mkdir -p " .. shQuote(loveDir) .. " " .. shQuote(borDir .. "/data"))
writeFile(loveDir .. "/main.lua", "return {}\n")
writeFile(tmp .. "/game.pak", "")
writeFile(tmp .. "/menu.pak", "")
writeFile(tmp .. "/readme.txt", "hi\n")

local loveRec = gamepid.engineOf(loveDir, "dir", {"main.lua"})
check(type(loveRec) == "table" and loveRec.id == "love", "a directory with main.lua is LÖVE")
check(loveRec and loveRec.start == engines.list[1].start, "confirm uses that engine's start script")
check(loveRec and loveRec.label == loveLabel, "the row tag is the engine label")
if loveRec then
    check(loveRec.startable == engines.startable(engines.list[1]), "startable follows the binary")
    if loveRec.startable then
        check(loveRec.hint == nil, "a startable engine has no install hint")
    else
        check(type(loveRec.hint) == "string" and loveRec.hint ~= "", "a missing binary keeps an install hint")
    end
end
do
    local savedBin = engines.list[1].binary
    local fakeBin = writeScript("fake-love", "#!/bin/sh\nexit 0\n")
    engines.list[1].binary = fakeBin
    local readyRec = gamepid.engineOf(loveDir, "dir", {"main.lua"})
    engines.list[1].binary = savedBin
    check(readyRec and readyRec.startable == true, "installed engine binary is startable")
    check(readyRec and readyRec.hint == nil, "installed engine has nil install hint")
end
check(gamepid.engineOf(loveDir, "file", nil) == nil, "the same directory is not a file game")
check(gamepid.engineOf(tmp .. "/game.pak", "file", nil).id == "openbor", "a pak file is OpenBOR")
check(gamepid.engineOf(tmp .. "/menu.pak", "file", nil) == nil, "menu.pak is not a game")
check(gamepid.engineOf(borDir, "dir", {"data"}).id == "openbor", "a data directory is OpenBOR")
check(gamepid.engineOf(tmp .. "/readme.txt", "file", nil) == nil, "a plain file is not a game")

local function commands(phase)
    return {
        confirm = gamepid.press(phase, "button", 1),
        back = gamepid.press(phase, "button", 2),
        voice = gamepid.press(phase, "button", gamepid.VOICE_BUTTON),
        quit = gamepid.press(phase, "button", 7),
        talk = gamepid.press(phase, "key", gamepid.VOICE_KEY),
        keyConfirm = gamepid.press(phase, "key", "return"),
        keyBack = gamepid.press(phase, "key", "left"),
        keyRight = gamepid.press(phase, "key", "right"),
        hatBack = gamepid.press(phase, "hat", "l"),
        hatRight = gamepid.press(phase, "hat", "ur"),
        up = gamepid.repeatDir(phase, "u", false, false),
        down = gamepid.repeatDir(phase, nil, false, true),
    }
end

local finderKeys = commands("finder")
check(finderKeys.confirm == "confirm" and finderKeys.keyConfirm == "confirm", "A confirms")
check(finderKeys.back == "back" and finderKeys.keyBack == "back" and finderKeys.hatBack == "back",
    "left and B go back")
check(finderKeys.keyRight == "right" and finderKeys.hatRight == "right", "right enters")
check(finderKeys.up == "up" and finderKeys.down == "down", "up and down move")
check(finderKeys.voice == "voice" and finderKeys.talk == "voice", "R1 and t stay the voice button")
check(finderKeys.quit == "quit", "SELECT still quits from the finder")

local failedKeys = commands("failed")
check(failedKeys.confirm == "confirm" and failedKeys.back == "back" and failedKeys.voice == "voice",
    "a failed start keeps the finder pad")

local runningKeys = commands("running")
check(runningKeys.confirm == nil and runningKeys.back == nil and runningKeys.quit == nil, "a game owns the pad")
check(runningKeys.keyConfirm == nil and runningKeys.up == nil and runningKeys.down == nil,
    "a game owns the arrows")
check(runningKeys.voice == "voice" and runningKeys.talk == "voice", "voice still works while a game runs")

local away = commands("away")
check(away.confirm == nil and away.back == "net" and away.voice == "voice" and away.quit == "quit",
    "without a finder, B still probes the net and R1 still talks")

local function lift(phase, x, y)
    local fired, gesture = gamepid.finger(phase, nil, true, x, y)
    check(fired == nil, "a press does not stop the game")
    return gamepid.finger(phase, gesture, false, x, y)
end

local stopCmd = lift("running", 500, 20)
check(stopCmd == "stop", "STOP GAME runs while a game is running")
local actionCmd = lift("running", 100, 20)
check(actionCmd == nil, "the server row is not a target here")
local idleCmd = lift("finder", 500, 20)
check(idleCmd == nil, "STOP GAME is absent while the finder is up")
local chatCmd = lift("running", 320, 200)
check(chatCmd == nil, "the chat log does not stop the game")

if failures > 0 then
    io.stderr:write(string.format("gamepid: %d failed, %d checks\n", failures, checks))
    done(1)
end
print(string.format("gamepid: %d ok", checks))
done(0)
