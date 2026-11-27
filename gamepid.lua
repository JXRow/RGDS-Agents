-- 上屏的游戏状态。纯函数：读 pid 文件，决定 finder 还是游戏，
-- 并把确认和 STOP GAME 接到启动、停止脚本。不画、不开窗口。
-- 服务器密码只用来从失败行里抹掉，这里不打印它。
--
-- read(path) 没有文件、读不出、或第一行不是 pid 时返回 nil。
-- 否则返回 {pid, id, path, alive}。alive 先是 kill -0，僵尸不算。
-- 进程还在时，还要 /proc/<pid>/environ 里有 RGDS_GAME_ID=<id>。
-- 对不上的活 pid 不算在跑。这里不打印 environ。
-- observe(state, reading) 返回新的 state，以及 "close"、"open" 或 nil。
-- 对得上的活 pid 关掉 finder。pid 没了再打开。选中项由调用方留着。
-- fail 把脚本的一行放进 notice，最多 180 个字符。finder 留着。
-- 轮询间隔是 0.25 秒，这样 start.sh 里 1 秒的等待够先关掉窗口。

local engines = require("engines")
local targets = require("targets")
local voicebutton = require("voicebutton")

local M = {}

M.POLL = 0.25
M.PID_FILE = "/tmp/rgds-game.pid"
M.NOTICE_LIMIT = 180
M.PASSWORD_FILE = "/userdata/opencode/server.password"
M.VOICE_BUTTON = voicebutton.DEFAULT_BUTTON
M.VOICE_KEY = "t"
M.VOICE_HINT = voicebutton.hint({
    button = voicebutton.DEFAULT_BUTTON,
    off = false,
    name = voicebutton.NAMES[voicebutton.DEFAULT_BUTTON],
})
M.FINDER_HINT = "UP DOWN MOVE  ·  LEFT B BACK  ·  RIGHT A OPEN  ·  A START  ·  R1 TALK"
M.FAIL_LINE = "game failed"

local function shQuote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function trimCr(line)
    if type(line) ~= "string" then return nil end
    if line:sub(-1) == "\r" then line = line:sub(1, -2) end
    return line
end

local function launchMarker(pid, id)
    if type(id) ~= "string" or id == "" then return false end
    local handle = io.open("/proc/" .. tostring(pid) .. "/environ", "rb")
    if not handle then return false end
    local text = handle:read("*a") or ""
    handle:close()
    local needle = "RGDS_GAME_ID=" .. id
    local from = 1
    while true do
        local at = text:find(needle, from, true)
        if not at then return false end
        local beforeOk = at == 1 or text:byte(at - 1) == 0
        local after = text:byte(at + #needle)
        if beforeOk and (after == nil or after == 0) then return true end
        from = at + 1
    end
end

function M.alive(pid)
    if type(pid) ~= "number" or pid < 1 or pid % 1 ~= 0 then return false end
    local status = os.execute("kill -0 " .. tostring(pid) .. " >/dev/null 2>&1")
    if not (status == true or status == 0) then return false end
    local handle = io.open("/proc/" .. tostring(pid) .. "/stat", "r")
    if not handle then return true end
    local text = handle:read("*a") or ""
    handle:close()
    if text:find(") Z ", 1, true) or text:find(") X ", 1, true) then
        return false
    end
    return true
end

function M.read(path)
    if path == nil or path == "" then path = M.PID_FILE end
    local handle = io.open(path, "r")
    if not handle then return nil end
    local pidLine = handle:read("*l")
    local id = handle:read("*l")
    local gamePath = handle:read("*l")
    handle:close()
    pidLine = trimCr(pidLine)
    if not pidLine then return nil end
    local digits = pidLine:match("^(%d+)$")
    local pid = digits and tonumber(digits)
    if not pid or pid < 1 then return nil end
    id = trimCr(id)
    gamePath = trimCr(gamePath)
    if id == "" then id = nil end
    if gamePath == "" then gamePath = nil end
    local alive = M.alive(pid)
    if alive and not launchMarker(pid, id) then
        alive = false
    end
    return {
        pid = pid,
        id = id,
        path = gamePath,
        alive = alive,
    }
end

local function lastLine(text)
    local last = ""
    if type(text) ~= "string" then return last end
    for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
        local line = trimCr(raw) or ""
        if line ~= "" then last = line end
    end
    return last
end

local function trimEdges(text)
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function replaceAll(text, needle, repl)
    if needle == "" then return text end
    local out, i = {}, 1
    while true do
        local from, to = text:find(needle, i, true)
        if not from then
            out[#out + 1] = text:sub(i)
            break
        end
        out[#out + 1] = text:sub(i, from - 1)
        out[#out + 1] = repl
        i = to + 1
        if i > #text then break end
    end
    return table.concat(out)
end

local function clipBytes(text, limit)
    if #text <= limit then return text end
    local cut = text:sub(1, limit)
    local i = #cut
    while i > 0 do
        local b = cut:byte(i)
        if b < 128 or b >= 192 then break end
        i = i - 1
    end
    if i == 0 then return "" end
    local b = cut:byte(i)
    if b >= 192 then
        local need = 2
        if b >= 240 then need = 4
        elseif b >= 224 then need = 3
        end
        if i + need - 1 > #cut then
            cut = cut:sub(1, i - 1)
        end
    end
    return cut
end

function M.readSecret(path)
    if path == nil or path == "" then path = M.PASSWORD_FILE end
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local line = handle:read("*l")
    handle:close()
    line = trimCr(line)
    if not line or line == "" then return nil end
    return line
end

function M.clip(text, secret)
    local line = trimEdges(lastLine(text))
    if type(secret) == "string" and secret ~= "" then
        line = replaceAll(line, secret, "[redacted]")
    end
    return clipBytes(line, M.NOTICE_LIMIT)
end

function M.blank()
    return {phase = "finder", notice = nil, game = nil}
end

function M.fail(state, line, secret)
    state = type(state) == "table" and state or M.blank()
    local notice = M.clip(line, secret)
    if notice == "" then notice = M.FAIL_LINE end
    local phase = state.phase or "finder"
    if phase ~= "running" then phase = "failed" end
    return {phase = phase, notice = notice, game = state.game}
end

function M.clearNotice(state)
    state = type(state) == "table" and state or M.blank()
    local phase = state.phase or "finder"
    if phase == "failed" then phase = "finder" end
    local game = nil
    if phase == "running" then game = state.game end
    return {phase = phase, notice = nil, game = game}
end

local function labelFor(id)
    if type(id) ~= "string" or id == "" then return "" end
    for i = 1, #engines.list do
        if engines.list[i].id == id then
            return engines.list[i].label
        end
    end
    return id
end

local function gameName(path)
    if type(path) ~= "string" or path == "" then return "" end
    return path:match("([^/]+)$") or path
end

function M.observe(state, reading, resolveVoice)
    state = type(state) == "table" and state or M.blank()
    if type(reading) == "table" and reading.alive == true then
        local effect = state.phase ~= "running" and "close" or nil
        local voice
        if state.phase == "running"
            and type(state.game) == "table"
            and state.game.pid == reading.pid
            and state.game.path == reading.path
            and state.game.voice ~= nil
        then
            voice = state.game.voice
        else
            voice = (resolveVoice or voicebutton.resolve)(reading.path)
        end
        return {
            phase = "running",
            notice = nil,
            game = {
                pid = reading.pid,
                id = reading.id,
                path = reading.path,
                name = gameName(reading.path),
                label = labelFor(reading.id),
                voice = voice,
            },
        }, effect
    end
    if state.phase == "running" then
        local notice = state.notice
        local phase = "finder"
        if type(notice) == "string" and notice ~= "" then phase = "failed" end
        return {phase = phase, notice = notice, game = nil}, "open"
    end
    return {
        phase = state.phase or "finder",
        notice = state.notice,
        game = nil,
    }, nil
end

function M.runningHint(state)
    local game = type(state) == "table" and state.game or nil
    if type(game) ~= "table" then return nil end
    local voiceHint = type(game.voice) == "table" and voicebutton.hint(game.voice) or M.VOICE_HINT
    return (game.label or "") .. "  ·  " .. (game.name or "") .. "  ·  " .. voiceHint
end

function M.press(phase, source, value, voice)
    if phase == "running" then
        if voice == nil then
            if source == "button" and value == M.VOICE_BUTTON then return "voice" end
            if source == "key" and value == M.VOICE_KEY then return "voice" end
            return nil
        end
        if voicebutton.listens(voice) then
            if source == "button" and value == voice.button then return "voice" end
            if source == "key" and value == M.VOICE_KEY then return "voice" end
        end
        return nil
    end
    if source == "button" and value == M.VOICE_BUTTON then return "voice" end
    if source == "key" and value == M.VOICE_KEY then return "voice" end
    if phase ~= "finder" and phase ~= "failed" then
        if source == "button" and value == 2 then return "net" end
        if source == "button" and value == 7 then return "quit" end
        return nil
    end
    if source == "button" then
        if value == 1 then return "confirm" end
        if value == 2 then return "back" end
        if value == 7 then return "quit" end
        return nil
    end
    if source == "key" then
        if value == "return" or value == "kpenter" or value == "a" then return "confirm" end
        if value == "left" or value == "b" or value == "backspace" then return "back" end
        if value == "right" then return "right" end
        return nil
    end
    if source == "hat" and type(value) == "string" then
        local left = value:find("l", 1, true) ~= nil
        local right = value:find("r", 1, true) ~= nil
        if left and not right then return "back" end
        if right and not left then return "right" end
    end
    return nil
end

function M.repeatDir(phase, hat, up, down)
    if phase ~= "finder" and phase ~= "failed" then return nil end
    if type(hat) == "string" then
        if hat:find("d", 1, true) then return "down" end
        if hat:find("u", 1, true) then return "up" end
    end
    if down then return "down" end
    if up then return "up" end
    return nil
end

function M.engineOf(path, kind, names)
    return engines.forFinder(path, kind, names)
end

function M.finger(phase, gesture, touchPhase, x, y)
    local list = targets.layout({game = phase == "running"})
    local fired, nextGesture = targets.step(list, gesture, touchPhase, x, y)
    local cmd = nil
    if type(fired) == "table" and fired.id == "stop" then
        cmd = "stop"
    end
    return cmd, nextGesture
end

function M.begin(script, gamePath, dir)
    if type(script) ~= "string" or script == "" then return false end
    if type(dir) ~= "string" or dir == "" then return false end
    local status = os.execute("mkdir -p " .. shQuote(dir))
    if not (status == true or status == 0) then return false end
    os.remove(dir .. "/code")
    os.remove(dir .. "/code.tmp")
    local args = ""
    if gamePath ~= nil then args = " " .. shQuote(gamePath) end
    local cmd = "(" .. shQuote(script) .. args
        .. " >" .. shQuote(dir .. "/out")
        .. " 2>" .. shQuote(dir .. "/err")
        .. " </dev/null; printf '%s\\n' \"$?\" >" .. shQuote(dir .. "/code.tmp")
        .. " && mv -f " .. shQuote(dir .. "/code.tmp") .. " " .. shQuote(dir .. "/code")
        .. ") >/dev/null 2>&1 &"
    status = os.execute(cmd)
    return status == true or status == 0
end

function M.finish(dir, secret)
    if type(dir) ~= "string" or dir == "" then return nil end
    local codePath = dir .. "/code"
    local handle = io.open(codePath, "r")
    if not handle then return nil end
    local raw = handle:read("*a") or ""
    handle:close()
    local code = tonumber(raw:match("(%d+)"))
    if not code then return nil end
    os.remove(codePath)
    local function take(name)
        local path = dir .. "/" .. name
        local handle = io.open(path, "r")
        local text = ""
        if handle then
            text = handle:read("*a") or ""
            handle:close()
        end
        os.remove(path)
        return text
    end
    if code == 0 then
        local text = take("out")
        take("err")
        return {ok = true, pid = tonumber(text:match("(%d+)"))}
    end
    if secret == nil then
        secret = M.readSecret(nil)
    elseif secret == false then
        secret = nil
    end
    local text = take("err")
    take("out")
    local notice = M.clip(text, secret)
    if notice == "" then notice = M.FAIL_LINE end
    return {ok = false, notice = notice}
end

return M
