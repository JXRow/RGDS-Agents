-- RGDS-Agents (Anbernic RG DS)。主窗口是 agent UI。
-- 两块屏时主窗口在 SDL display 1（下屏，LÖVE 编号 2），第二个窗口在 SDL display 0（上屏，留给 finder）。
-- 一块屏或 --one-screen 时只有主窗口。见 screens.lua、subscreen.lua。
-- 花园演示已退役：不画草地、标题卡、分数和状态块，也不再用按键走路或开始一局。
-- 麦克风波形与电平（micwave.lua / micthread.lua，经 dsnoop 共享录音）；
-- 按住 R1（键盘 t）录一段语音。松开后交给常驻的 sv-helper（stt.lua）做离线识别，
-- 识别出文字后再交给 rgds-aid。回复留在主窗口，长回复换行，十字键上下滚动。
-- gt9xx-0 的触摸在主窗口（下屏）上。server 行的操作在手指抬起时触发。手柄保留。

local W, H = 640, 480
local windowW, windowH = W, H
local player
local seed
local petals = {}
local sparks = {}
local time = 0
local score = 0
local best = 0
local started = false
local pulse = 0
local runtime = {}
local fonts = {}
local lastInput = {type = "none", code = "", name = "", time = -10}
local shutdownDialog = false
local net = {state = "?", detail = "not probed"}
local selftest = false
local inputlog = false

local audio = {enabled = false, sfx = {}, bgm = nil, error = nil}
local micwave = require("micwave")
local stt = require("stt")
local aid = require("aid")
local aidSeen = 0
local PTT_BUTTON = 6                     -- R1：A/B/START/SELECT 已占用，食指按住不影响移动和 A
local ptt = {held = false, bgmPaused = false}
local touchGoal = nil
local lastTapAt, lastTapX, lastTapY = -10, 0, 0
local evdev = require("evdev")
local touchpoll = require("touchpoll")
local serverstate = require("serverstate")
local targets = require("targets")
local beginFromTap
local clampPlay
local INPUT_LOG = "/tmp/rgds-input-v2.log"
local shotRequested = false
local shotTaken = false
local shotFrames = 0

local palette = {
    sky = {0.08, 0.12, 0.22},
    sky2 = {0.12, 0.18, 0.31},
    ink = {0.05, 0.07, 0.13},
    grass = {0.15, 0.28, 0.25},
    grass2 = {0.19, 0.36, 0.29},
    cream = {0.95, 0.88, 0.66},
    gold = {1.0, 0.68, 0.24},
    pink = {1.0, 0.42, 0.55},
    mint = {0.39, 0.91, 0.72},
    purple = {0.57, 0.45, 0.93}
}

local function color(name, alpha)
    local c = palette[name]
    love.graphics.setColor(c[1], c[2], c[3], alpha or 1)
end

local subscreen = require("subscreen")
local screens = require("screens")
local hud = {external = false, error = nil}
local screenPlan

-- 游玩区（草地区域）边界；信息面板在第二块屏时草地占满主屏
local SHARED_FIELD_TOP = 214
local FIELD_TOP, PLAYER_MIN_Y, PLAYER_MAX_Y

local function setFieldTop(top)
    FIELD_TOP = top
    PLAYER_MIN_Y, PLAYER_MAX_Y = FIELD_TOP + 46, H - 28
end
setFieldTop(SHARED_FIELD_TOP)

local function randomPoint(margin)
    return {
        x = margin + math.random() * (W - margin * 2),
        y = PLAYER_MIN_Y + math.random() * (PLAYER_MAX_Y - PLAYER_MIN_Y)
    }
end

local function spawnSeed()
    seed = randomPoint(40)
    seed.phase = math.random() * math.pi * 2
end

local function reset()
    player = {x = W / 2, y = PLAYER_MAX_Y - 10, r = 16, speed = 245, trail = {}}
    score = 0
    started = false
    pulse = 0
    touchGoal = nil
    spawnSeed()
    if audio.bgm then audio.bgm:stop() end
end

local function addSpark(x, y, count)
    for _ = 1, count do
        local angle = math.random() * math.pi * 2
        local speed = 45 + math.random() * 130
        sparks[#sparks + 1] = {
            x = x, y = y,
            vx = math.cos(angle) * speed,
            vy = math.sin(angle) * speed,
            life = 0.45 + math.random() * 0.45,
            size = 2 + math.random() * 3
        }
    end
end

local function addPetal()
    petals[#petals + 1] = {
        x = math.random() * W,
        y = FIELD_TOP + math.random() * (H - FIELD_TOP),
        speed = 14 + math.random() * 25,
        drift = math.random() * math.pi * 2,
        size = 2 + math.random() * 3
    }
end

local function isDown(keys)
    for _, key in ipairs(keys) do
        if love.keyboard.isDown(key) then return true end
    end
    return false
end

local function drawRoundedBox(x, y, w, h, radius, fill, alpha)
    color(fill, alpha)
    love.graphics.rectangle("fill", x, y, w, h, radius, radius)
end

-- === 音频合成（不依赖外部文件） ===
local function makeTone(waveType, freq, dur, vol, sweep, decay)
    local sampleRate = 44100
    local nSamples = math.floor(sampleRate * dur)
    local sd = love.sound.newSoundData(nSamples, sampleRate, 16, 1)
    for i = 0, nSamples - 1 do
        local t = i / sampleRate
        local f = freq + (sweep or 0) * t
        local phase = t * f * math.pi * 2
        local sample
        if waveType == "square" then
            sample = (math.sin(phase) > 0) and 1 or -1
        elseif waveType == "triangle" then
            sample = 2 / math.pi * math.asin(math.sin(phase))
        elseif waveType == "noise" then
            sample = math.random() * 2 - 1
        else
            sample = math.sin(phase)
        end
        local atk = 0.01
        local env
        if t < atk then
            env = t / atk
        else
            env = math.exp(-(t - atk) * (decay or 6))
        end
        sd:setSample(i, sample * env * vol)
    end
    return sd
end

-- 播放设备被占用时 LÖVE 11 会打印 "Could not open device." 并静默换成 null 驱动：
-- newSource 照常成功，但 play() 返回 false、isPlaying() 永远为 false。
local function playbackDeviceWorks()
    local probe = love.audio.newSource(love.sound.newSoundData(11025, 44100, 16, 1), "static")
    probe:setVolume(0)
    local works = probe:play() and probe:isPlaying()
    probe:stop()
    probe:release()
    return works
end

-- 启动脚本把 stdout 重定向到 $RGDS_LOG，LÖVE 加载 audio 模块时的报错会先写进去
local function launcherLogReportsNoDevice()
    local path = os.getenv("RGDS_LOG")
    local f = path and io.open(path, "r")
    if not f then return false end
    local text = f:read("*a") or ""
    f:close()
    return text:find("Could not open device", 1, true) ~= nil
end

local function initAudio()
    audio.enabled = false
    local ok, err = pcall(function()
        if not playbackDeviceWorks() or launcherLogReportsNoDevice() then
            error("no playback device (OpenAL fell back to null driver; device busy?)", 0)
        end
        audio.sfx.collect = love.audio.newSource(makeTone("sine", 523, 0.15, 0.3, 800, 8), "static")
        audio.sfx.start = love.audio.newSource(makeTone("triangle", 392, 0.3, 0.25, 200, 4), "static")
        audio.sfx.reset = love.audio.newSource(makeTone("square", 440, 0.2, 0.15, -600, 7), "static")
        audio.sfx.shutdown = love.audio.newSource(makeTone("sine", 330, 0.4, 0.2, -100, 3), "static")

        local bgmRate, bgmDur = 22050, 4.0
        local bgmSamples = math.floor(bgmRate * bgmDur)
        local bgmSd = love.sound.newSoundData(bgmSamples, bgmRate, 16, 1)
        local notes = {261.63, 329.63, 392.00, 523.25, 392.00, 329.63}
        local noteDur = bgmDur / #notes
        for i = 0, bgmSamples - 1 do
            local t = i / bgmRate
            local f = notes[math.floor(t / noteDur) % #notes + 1]
            local noteT = t % noteDur
            local phase = noteT * f * math.pi * 2
            local sample = math.sin(phase) * 0.5 + math.sin(phase * 2) * 0.15
            local env = math.exp(-noteT * 3) * (1 - math.exp(-noteT * 50))
            bgmSd:setSample(i, sample * env * 0.12)
        end
        audio.bgm = love.audio.newSource(bgmSd, "stream")
        audio.bgm:setLooping(true)
        audio.bgm:setVolume(0.45)
    end)
    if ok then
        audio.enabled = true
    else
        audio.error = tostring(err)
    end
end

local function playSfx(name)
    if not audio.enabled or micwave.recording then return end
    local src = audio.sfx[name]
    if src then
        src:stop()
        src:play()
    end
end

local function startBgm()
    if not audio.enabled or not audio.bgm then return end
    if micwave.recording then
        ptt.bgmPaused = true                 -- 录音结束后再开始
        return
    end
    if not audio.bgm:isPlaying() then audio.bgm:play() end
end

-- === 按键录音（push-to-talk） ===
-- 麦克风会拾到扬声器里的 BGM，录音期间暂停 BGM、静音音效，录完（含 0.2 s 尾巴）再恢复
local function pttPress()
    if ptt.held or shutdownDialog or serverRow.holdChat then return end
    if not micwave.beginClip() then return end
    aid.dismiss()
    ptt.held = true
    if audio.enabled and audio.bgm and audio.bgm:isPlaying() then
        audio.bgm:pause()
        ptt.bgmPaused = true
    end
end

local function pttRelease()
    if not ptt.held then return end
    ptt.held = false
    micwave.endClip()
end

local function pttResumeMusic()
    if not ptt.bgmPaused or micwave.recording then return end
    ptt.bgmPaused = false
    if started and audio.enabled and audio.bgm and not audio.bgm:isPlaying() then audio.bgm:play() end
end

-- === 网络探测 ===
-- RGDS 自带 Buildroot 没有 libcurl；优先用系统 curl，其次 python3。
local NET_URL = "https://jazz-api.jianda.com/music/recommend/guest?order=balanced&language=none"
local NET_UA = "BlueJazzClub-RGDS/1.0"

-- 掌机的 /usr/bin/curl 是 python 精简版，只认 -o -O -L -s -f -I -S --max-time -H --range
local NET_MAX_TIME = 8
local NET_WATCHDOG = NET_MAX_TIME + 4
local NET_CHANNEL = "rgds-netprobe"

-- curl 在 love.thread 里跑，主循环每帧只 pop 一次结果，探测期间照常渲染
local NET_THREAD_CODE = [[
require("love.thread")
local cmd = ...
local ok, pipe = pcall(io.popen, cmd)
local out = ""
if ok and pipe then
    out = pipe:read("*a") or ""
    pipe:close()
end
love.thread.getChannel("rgds-netprobe"):push(out)
]]

local netProbe = nil   -- {thread, started, frames, maxDt}

local function finishNet(state, detail)
    net.state, net.detail = state, detail
    if netProbe then
        print(string.format("netprobe: %s (%s) in %.2fs; %d frames rendered meanwhile, max frame %.0f ms",
            state, detail, love.timer.getTime() - netProbe.started, netProbe.frames, netProbe.maxDt * 1000))
        io.stdout:flush()
    end
    netProbe = nil
end

local function probeNet()
    if netProbe then return end
    local cmd = string.format(
        'curl -s -f -o /dev/null --max-time %d -H "User-Agent: %s" "%s" 2>/dev/null; echo " rc=$?"',
        NET_MAX_TIME, NET_UA, NET_URL)
    love.thread.getChannel(NET_CHANNEL):clear()
    local ok, thread = pcall(love.thread.newThread, NET_THREAD_CODE)
    if not ok then
        net.state, net.detail = "n/a", "no thread"
        return
    end
    thread:start(cmd)
    netProbe = {thread = thread, started = love.timer.getTime(), frames = 0, maxDt = 0}
    net.state, net.detail = "checking", "..."
end

local function pollNet(dt)
    if not netProbe then return end
    netProbe.frames = netProbe.frames + 1
    netProbe.maxDt = math.max(netProbe.maxDt, dt)
    local out = love.thread.getChannel(NET_CHANNEL):pop()
    if out == nil then
        if netProbe.thread:getError() then
            finishNet("n/a", "thread error")
        elseif love.timer.getTime() - netProbe.started > NET_WATCHDOG then
            finishNet("fail", "timeout")
        end
        return
    end
    local rc = tonumber(out:match("rc=(%d+)"))
    if rc == 0 then
        finishNet("online", "catalog 200")
    elseif rc then
        finishNet("fail", "curl rc=" .. rc)
    else
        finishNet("n/a", "no curl")
    end
end


-- === OpenCode server 行 ===
-- 状态脚本在 love.thread 里跑，跟上面的网络探测一样。不看 file:close() 的返回值。
-- 每帧 serverstate.map 出一行。手指只走 touchpoll，抬起在目标内才触发。
-- game 保持 false：STOP GAME 留给第 7 步。
local SERVER_CHANNEL = "rgds-server"
local SHELL_THREAD = [[
require("love.thread")
local channel, token, cmd = ...
local ok, pipe = pcall(io.popen, cmd)
local out = ""
if ok and pipe then
    out = pipe:read("*a") or ""
    pipe:close()
end
love.thread.getChannel(channel):push({token = token, out = out})
]]
local WIZARD_THREAD = [[
require("love.thread")
local cmd = ...
os.execute("(trap '' HUP; exec " .. cmd .. " >/dev/null 2>&1) &")
]]

local shellJob = nil
local shellToken = 0
local queuedAction = nil
local wizardThreads = {}
local serverStatusLine, serverStatusExit = nil, nil
local serverStartPending = false
local serverStartExit, serverStartLine = nil, nil
local serverAdapter, serverLastStatus = nil, nil
local unhealthySince = nil
local serverPollAt = 0
local fingerGesture = nil
local serverRow = {
    state = "starting",
    word = serverstate.word.starting,
    detail = "Checking the server",
    action = nil,
    holdChat = true,
}

local SERVER_KIND = {auth = true, offline = true, server = true, helper = true}
local TURN_KIND = {timeout = true, rate_limit = true, interrupted = true, cancelled = true}

local function serviceScript()
    return love.filesystem.getSource() .. "/" .. serverstate.paths.service
end

local function noteAdapter(msg)
    if type(msg) ~= "table" then return end
    if msg.ev == "status" then
        serverLastStatus = msg
        serverAdapter = msg
    elseif msg.ev == "error" and (SERVER_KIND[msg.kind] or TURN_KIND[msg.kind]) then
        serverAdapter = msg
    end
end

aid.onEvent = noteAdapter

local function refreshServerRow()
    local now = love.timer.getTime()
    local parsed = serverstate.parseStatus(serverStatusLine)
    local unhealthy = nil
    if parsed and parsed.health == "unhealthy" then
        if not unhealthySince then unhealthySince = now end
        unhealthy = now - unhealthySince
    else
        unhealthySince = nil
    end
    serverRow = serverstate.map({
        configPath = serverstate.paths.configFile,
        setupPath = serverstate.paths.setupFile,
        statusLine = serverStatusLine,
        statusExit = serverStatusExit,
        adapter = serverAdapter,
        lastStatus = serverLastStatus,
        phase = aid.phase,
        startPending = serverStartPending,
        startExit = serverStartExit,
        startLine = serverStartLine,
        unhealthySeconds = unhealthy,
    })
end

local function serverTargets()
    return targets.layout({action = serverRow.action, game = false})
end

local function reapWizards()
    local live = {}
    for i = 1, #wizardThreads do
        local thread = wizardThreads[i]
        local running = false
        pcall(function() running = thread:isRunning() end)
        if running then live[#live + 1] = thread end
    end
    wizardThreads = live
end

local function spawnWizard()
    reapWizards()
    local cmd = serverstate.actionCommand(
        "wizard", nil, love.filesystem.getSource() .. "/" .. serverstate.paths.wizard)
    if not cmd then return end
    local ok, thread = pcall(love.thread.newThread, WIZARD_THREAD)
    if not ok or not thread then return end
    local started = false
    local callOk = pcall(function() started = thread:start(cmd) end)
    if callOk and started ~= false then
        wizardThreads[#wizardThreads + 1] = thread
    end
end

local function startShell(kind, cmd)
    if shellJob then return false end
    shellToken = shellToken + 1
    local token = shellToken
    love.thread.getChannel(SERVER_CHANNEL):clear()
    local ok, thread = pcall(love.thread.newThread, SHELL_THREAD)
    if not ok or not thread then return false end
    local started = false
    local callOk = pcall(function()
        started = thread:start(SERVER_CHANNEL, token, cmd)
    end)
    if not callOk or started == false then return false end
    shellJob = {thread = thread, kind = kind, token = token}
    return true
end

local function launchAction(op)
    local cmd = serverstate.actionCommand(op, serviceScript())
    if not cmd or not startShell("action", cmd) then
        serverStartPending = false
        return false
    end
    return true
end

local function runServerAction(op)
    if op == "wizard" then
        spawnWizard()
        return
    end
    if op ~= "start" and op ~= "restart" then return end
    if serverStartPending then return end
    serverStartPending = true
    serverStartExit, serverStartLine = nil, nil
    if shellJob then
        queuedAction = op
        return
    end
    launchAction(op)
end

local function finishShell(out)
    local kind = shellJob.kind
    shellJob = nil
    if kind == "action" then
        serverStartPending = false
        if out == nil then
            serverStartExit, serverStartLine = 1, "start failed"
        else
            serverStartLine, serverStartExit = serverstate.parseProbe(out)
        end
        serverPollAt = 0
    elseif out ~= nil then
        serverStatusLine, serverStatusExit = serverstate.parseProbe(out)
    end
    if kind ~= "action" and queuedAction then
        local op = queuedAction
        queuedAction = nil
        launchAction(op)
    end
end

local function takeShell()
    if not shellJob then return end
    local msg = love.thread.getChannel(SERVER_CHANNEL):pop()
    if msg == nil then
        local failed = false
        pcall(function() failed = shellJob.thread:getError() ~= nil end)
        if failed then finishShell(nil) end
        return
    end
    if type(msg) ~= "table" or msg.token ~= shellJob.token then return end
    finishShell(msg.out or "")
end

local function maybeProbe()
    reapWizards()
    if serverRow.state == "running" or shellJob then return end
    local now = love.timer.getTime()
    if now < serverPollAt then return end
    local cmd = serverstate.probeCommand(serviceScript())
    if not startShell("status", cmd) then return end
    serverPollAt = now + serverstate.POLL_S
    aid.askStatus()
end

local function onInfoFinger(phase, x, y)
    local fired
    fired, fingerGesture = targets.step(serverTargets(), fingerGesture, phase, x, y)
    if not fired or fired.id == "stop" then return end
    if fired.id == "action" then runServerAction(fired.op) end
end

-- --shot 模式：依次拍开场 / 游玩 / 确认对话框，然后退出
local shotStage = 0
local function tickShot()
    if shotStage >= 4 then return end
    shotStage = shotStage + 1
    if shotStage == 1 then
        love.graphics.captureScreenshot("shot-1-intro.png")
    elseif shotStage == 2 then
        started = true
        score = 7
        addSpark(seed.x, seed.y, 14)
        love.graphics.captureScreenshot("shot-2-play.png")
    elseif shotStage == 3 then
        shutdownDialog = true
        love.graphics.captureScreenshot("shot-3-dialog.png")
    else
        love.timer.sleep(0.4)
        love.event.quit()
    end
end

-- === 输入映射 ===
-- 依据掌机自带 RetroArch 配置 /oem/retro/autoconfig/udev/ANBERNIC-rk3568-keys.cfg
-- （该文件用 0 基按钮号，LÖVE 用 1 基，因此这里整体 +1）
local BUTTONS = {
    [1] = "A", [2] = "B", [3] = "Y", [4] = "X",
    [5] = "L1", [6] = "R1", [7] = "SELECT", [8] = "START",
    [10] = "L3", [11] = "L2", [12] = "R2", [13] = "R3"
}

local HAT_NAMES = {
    c = "CENTER", u = "UP", d = "DOWN", l = "LEFT", r = "RIGHT",
    ul = "UP+LEFT", ur = "UP+RIGHT", dl = "DOWN+LEFT", dr = "DOWN+RIGHT"
}

local inputLogFile

local function recordInput(eventType, code, name)
    lastInput = {type = eventType, code = tostring(code), name = tostring(name), time = time}
    if inputlog and inputLogFile then
        inputLogFile:write(string.format("%8.3f\t%s\t%s\t%s\n", time, eventType, tostring(code), tostring(name)))
        inputLogFile:flush()
    end
end

-- 内置字体没有中文和日文。思源黑体 CN 带汉字、假名和拉丁字母。
local function loadCjkFont(size)
    local rel = "fonts/SourceHanSansCN-Regular.otf"
    local abs = "/usr/share/fonts/source-han-sans-cn/SourceHanSansCN-Regular.otf"
    local path = love.filesystem.getInfo(rel) and rel or abs
    local ok, font = pcall(love.graphics.newFont, path, size)
    if ok and font then
        font:setFilter("linear", "linear")
        print("stt: CJK font " .. path)
        io.stdout:flush()
        return font
    end
    print("stt: no CJK font (" .. tostring(font) .. ")")
    io.stdout:flush()
    return nil
end

local sdlWatch

function installTouchWatch()
    local ffi = require("ffi")
    local ok, err = pcall(function()
        ffi.cdef[[
            typedef int (*rgds_event_watch)(void *userdata, void *event);
            void SDL_AddEventWatch(rgds_event_watch filter, void *userdata);
        ]]
    end)
    if not ok and not tostring(err):find("attempt to redefine", 1, true) then
        print("touch: sdl cdef " .. tostring(err))
        io.stdout:flush()
        return
    end
    local function onEvent(_, event)
        local base = ffi.cast("uint8_t*", event)
        local typ = ffi.cast("uint32_t*", base)[0]
        if typ < 0x700 or typ > 0x702 then return 0 end
        local x = ffi.cast("float*", base + 24)[0]
        local y = ffi.cast("float*", base + 28)[0]
        local win = ffi.cast("uint32_t*", base + 44)[0]
        if not (x > 1.5 or y > 1.5) then
            x, y = x * W, y * H
        end
        print(string.format("touch: sdl %d %.0f,%.0f win %d", typ, x, y, win))
        io.stdout:flush()
        if typ == 0x701 then
            noteFinger(false, x, y)
        elseif typ == 0x702 then
            noteFinger("move", x, y)
        else
            noteFinger(true, x, y)
        end
        return 0
    end
    local hooked, hookErr = pcall(function()
        sdlWatch = ffi.cast("rgds_event_watch", onEvent)
        ffi.C.SDL_AddEventWatch(sdlWatch, nil)
    end)
    print("touch: sdl watch " .. (hooked and "on" or tostring(hookErr)))
    io.stdout:flush()
end

local function placeMainWindow(oneScreen)
    local count
    local countOk, n = pcall(function() return love.window.getDisplayCount() end)
    if countOk then count = n end
    local planned = screens.plan(count, oneScreen)
    if planned.loveDisplay == 1 or not love.window.isVisible() then
        return planned
    end
    local modeOk, _, _, flags = pcall(love.window.getMode)
    flags = modeOk and flags or {}
    local setOk, moved = pcall(love.window.setMode, W, H, {
        fullscreen = flags.fullscreen,
        fullscreentype = flags.fullscreentype,
        borderless = flags.borderless,
        resizable = false,
        vsync = 1,
        highdpi = false,
        display = planned.loveDisplay,
    })
    local checkOk, _, _, placed = pcall(love.window.getMode)
    if setOk and moved and checkOk and placed and placed.display == planned.loveDisplay then
        return planned
    end
    return screens.plan(1), "could not move the main window"
end

function love.load()
    local oneScreen = false
    for _, value in ipairs(arg or {}) do
        if value == "--selftest" then selftest = true end
        if value == "--inputlog" then inputlog = true end
        if value == "--shot" then shotRequested = true end
        if value == "--one-screen" then oneScreen = true end
    end

    local placeErr
    screenPlan, placeErr = placeMainWindow(oneScreen)

    love.graphics.setDefaultFilter("nearest", "nearest")
    for _, size in ipairs({8, 9, 10, 11, 12, 14, 16, 20, 22, 28}) do
        fonts[size] = love.graphics.newFont(size)
    end
    fonts.cjk = loadCjkFont(16)

    love.math.setRandomSeed(os.time())
    initAudio()
    local micOk, micErr = micwave.start()
    print("mic: " .. (micOk and ("recorder thread started, ALSOFT_CONF=" .. tostring(os.getenv("ALSOFT_CONF")))
        or ("off (" .. tostring(micErr) .. ")")))
    micwave.onClip = function(c)
        if c.ok and c.sound then
            stt.submit(c.sound:getString())
        end
    end
    stt.start()
    aid.start()
    windowW, windowH = love.graphics.getWidth(), love.graphics.getHeight()

    if not screenPlan.openSecondWindow then
        hud.error = placeErr or (oneScreen and "disabled by --one-screen" or "single display")
    elseif not love.window.isVisible() then
        hud.error = "main window hidden"
    else
        local ok, err = subscreen.open(W, H)
        if ok and (subscreen.mainDisplay ~= screenPlan.agentsSdl or subscreen.display ~= screenPlan.secondSdl) then
            subscreen.close()
            ok = false
            err = string.format("displays main %s second %s, wanted %d and %d",
                tostring(subscreen.mainDisplay), tostring(subscreen.display),
                screenPlan.agentsSdl, screenPlan.secondSdl)
        end
        hud.external, hud.error = ok, err
    end
    if hud.external then
        print(string.format("subscreen: second window on display %d (main window on display %d)",
            subscreen.display, subscreen.mainDisplay))
    else
        print("subscreen: off (" .. tostring(hud.error) .. "), one window")
    end
    io.stdout:flush()

    local renderer, version, vendor, device = love.graphics.getRendererInfo()
    local major, minor, revision = love.getVersion()
    local joysticks = love.joystick.getJoysticks()
    runtime = {
        os = love.system.getOS(),
        renderer = tostring(renderer) .. " " .. tostring(version),
        gpu = tostring(vendor) .. " / " .. tostring(device),
        input = #joysticks > 0 and ("Pad: " .. tostring(joysticks[1]:getName())) or "Keyboard only",
        output = hud.external and string.format("%d x %d on display %d, second window on display %d",
            windowW, windowH, subscreen.mainDisplay, subscreen.display)
            or string.format("%d x %d", windowW, windowH),
        lua = _VERSION .. " / LÖVE " .. string.format("%d.%d.%d", major, minor, revision)
    }

    if inputlog then
        inputLogFile = io.open(INPUT_LOG, "w")
        if inputLogFile then
            inputLogFile:write("# t\ttype\tcode\tname\n")
        end
    end

    for _ = 1, 24 do addPetal() end
    reset()

    -- Weston 不把 gt9xx-0 派发给 SDL。下屏的点按从 event1 直接读。
    local evOk, evErr = evdev.open(nil, W, H, function(phase, x, y)
        noteFinger(phase, x, y)
    end)
    if not evOk then
        print("evdev: off (" .. tostring(evErr) .. ")")
        io.stdout:flush()
    end
    installTouchWatch()
    local tpOk, tpErr = touchpoll.open(function(phase, x, y)
        onInfoFinger(phase, x, y)
    end)
    if not tpOk then
        print("touchpoll: off (" .. tostring(tpErr) .. ")")
        io.stdout:flush()
    end

    if selftest then
        love.filesystem.write("selftest.txt", "")
        probeNet()
        maybeProbe()
        love.timer.sleep(1.2)     -- 让帧率统计稳定
        return
    end
    probeNet()
    maybeProbe()
end

function love.resize(width, height)
    windowW, windowH = width, height
end

function love.quit()
    evdev.close()
    touchpoll.close()
    micwave.stop()
    stt.stop()
    aid.stop()
    subscreen.close()
end

-- 信息屏上的对话：比窗口高时，十字键上/下逐行滚动。流式回复默认贴着最新一行。
local CHAT_W, CHAT_H = 616, 318
local chatLines = {}
local chatScroll = 0
local chatStick = true
local chatView = 1
local chatMax = 0
local chatEpoch = 0
local chatRev = -1
local chatOverflow = false
local scrollArm = nil

local function layoutChat()
    if chatRev == aid.rev then return end
    if aid.hasLog() and not (fonts.cjk or fonts[16]) then return end
    chatRev = aid.rev
    chatLines = {}
    chatOverflow = false
    chatMax = 0
    if not aid.hasLog() then return end
    local font = fonts.cjk or fonts[16]
    love.graphics.setFont(font)
    local lh = font:getHeight()
    local boxH = serverRow.setup and (CHAT_H - 18) or CHAT_H
    chatView = math.max(1, math.floor((boxH - 20) / lh))
    local function pushWrapped(tag, body, textColor, textAlpha)
        if body == nil or body == "" then return end
        local tagW = font:getWidth(tag)
        local limit = math.max(40, CHAT_W - 36 - tagW)
        local _, wrapped = font:getWrap(body, limit)
        if #wrapped == 0 then wrapped = {body} end
        for i, line in ipairs(wrapped) do
            chatLines[#chatLines + 1] = {
                text = line,
                tag = i == 1 and tag or nil,
                tagW = tagW,
                color = textColor,
                alpha = textAlpha,
            }
        end
    end
    for i, turn in ipairs(aid.log) do
        if i > 1 then
            chatLines[#chatLines + 1] = {text = "", gap = true, color = "cream", alpha = 0}
        end
        if turn.who == "you" then
            local tag = aid.youTag(turn) .. "  "
            pushWrapped(tag, turn.text, "cream", 0.62)
        else
            local body = turn.text
            if body == "" and turn.live then body = fonts.cjk and "…" or "..." end
            pushWrapped("AI  ", body, "cream", 1)
            local toolLine = aid.toolText(turn.tool)
            if toolLine then
                local tag = body == "" and "AI  " or "    "
                local textColor, alpha = "gold", 0.62
                if turn.tool.status == "error" then
                    textColor, alpha = "pink", 1
                elseif turn.live and turn.tool.status == "running" then
                    alpha = 1
                end
                pushWrapped(tag, toolLine, textColor, alpha)
            end
            if turn.err and turn.err ~= "" then
                pushWrapped("    ", turn.err, "pink", 1)
            end
        end
    end
    chatMax = math.max(0, #chatLines - chatView)
    chatOverflow = chatMax > 0
    if chatStick then
        chatScroll = chatMax
    else
        if chatScroll > chatMax then chatScroll = chatMax end
        if chatScroll >= chatMax then chatStick = true end
    end
end

local function toGame(x, y)
    local ww = math.max(1, love.graphics.getWidth())
    local wh = math.max(1, love.graphics.getHeight())
    return x * W / ww, y * H / wh
end

function clampPlay(x, y)
    return math.max(32, math.min(W - 32, x)),
        math.max(PLAYER_MIN_Y, math.min(PLAYER_MAX_Y, y))
end

-- 同一次点按在 Wayland 上经常先到 touch 再到 mouse，80ms 内的同一落点只处理一次。
local function duplicateTap(x, y)
    local now = love.timer.getTime()
    if now - lastTapAt < 0.08 and math.abs(x - lastTapX) < 12 and math.abs(y - lastTapY) < 12 then
        return true
    end
    lastTapAt, lastTapX, lastTapY = now, x, y
    return false
end

-- evdev、SDL 和鼠标也会进到这里。下屏目标只认 touchpoll 的坐标。
function noteFinger(phase, x, y)
end

function beginFromTap(x, y)
    if shutdownDialog or selftest then return end
    if duplicateTap(x, y) then return end
    if not started then
        started = true
        playSfx("start")
        startBgm()
    end
    if x < 0 or x > W or y < FIELD_TOP or y > H then return end
    local gx, gy = clampPlay(x, y)
    touchGoal = {x = gx, y = gy}
    print(string.format("touch: walk %.0f,%.0f", gx, gy))
    io.stdout:flush()
end

local function nudgeChat(dir)
    if dir < 0 then
        if chatScroll <= 0 then return end
        chatStick = false
        chatScroll = chatScroll - 1
    elseif chatScroll < chatMax then
        chatScroll = chatScroll + 1
        if chatScroll >= chatMax then chatStick = true end
    else
        chatStick = true
    end
end

-- 按住十字键上或下时返回 true，这一帧不再用上下移动角色
local function pollChatScroll()
    if aid.epoch ~= chatEpoch then
        chatEpoch = aid.epoch
        chatStick = true
    end
    layoutChat()
    if not chatOverflow then
        scrollArm = nil
        return false
    end
    local dir = 0
    local joystick = love.joystick.getJoysticks()[1]
    if joystick then
        local hat = joystick:getHat(1) or ""
        if hat:find("u", 1, true) then dir = -1 end
        if hat:find("d", 1, true) then dir = 1 end
    end
    if dir == 0 then
        if isDown({"up"}) then dir = -1 end
        if isDown({"down"}) then dir = 1 end
    end
    if dir == 0 or shutdownDialog then
        scrollArm = nil
        return false
    end
    local now = love.timer.getTime()
    if not scrollArm or now >= scrollArm then
        nudgeChat(dir)
        scrollArm = now + (scrollArm and 0.09 or 0.32)
    end
    return true
end

function love.update(dt)
    refreshServerRow()
    evdev.pump()
    touchpoll.pump()
    pollNet(dt)
    micwave.update(dt)
    stt.update()
    aid.update()
    takeShell()
    refreshServerRow()
    maybeProbe()
    if stt.serial ~= aidSeen and not serverRow.holdChat then
        aidSeen = stt.serial
        if stt.text and stt.text ~= "" then aid.chat(stt.text, stt.lang) end
    end
    pttResumeMusic()
    if shotRequested and shotStage < 4 then
        shotFrames = shotFrames + 1
        if shotFrames > 40 then
            shotFrames = 0
            tickShot()
        end
        time = time + dt
        return
    end
    if selftest then
        time = time + dt
        return
    end
    time = time + dt
    pollChatScroll()
end

function love.keypressed(key, scancode)
    recordInput("keypressed", scancode or key, key)
    if key == "escape" then love.event.quit() end
    if key == "n" then probeNet() end
    if key == "t" then pttPress() end
end

function love.keyreleased(key)
    if key == "t" then pttRelease() end
end

function love.joystickpressed(joy, button)
    local name = BUTTONS[button] or ("BTN" .. button)
    recordInput("joystick", button, name)
    if shutdownDialog then
        if button == 1 then
            playSfx("shutdown")
            love.event.quit()
        elseif button == 2 then
            shutdownDialog = false
        end
        return
    end
    if button == 2 then                         -- B
        probeNet()
    elseif button == 7 then                     -- SELECT
        pttRelease()
        shutdownDialog = true
    elseif button == PTT_BUTTON then
        pttPress()
    end
end

function love.joystickreleased(joy, button)
    if button == PTT_BUTTON then pttRelease() end
end

function love.joystickhatpressed(_, hat, value)
    recordInput("hat", hat, HAT_NAMES[value] or value)
end

function love.joystickaxis(joy, axis, value)
    if math.abs(value) > 0.6 then
        recordInput("axis", axis, string.format("%.2f", value))
    end
end

function love.touchpressed(id, x, y)
    local gx, gy = toGame(x, y)
    recordInput("touch", id, string.format("%.0f,%.0f", gx, gy))
    noteFinger(true, gx, gy)
end

function love.touchmoved(id, x, y)
    noteFinger("move", toGame(x, y))
end

function love.mousepressed(x, y, button)
    local gx, gy = toGame(x, y)
    recordInput("mouse", button, string.format("%.0f,%.0f", gx, gy))
    if button ~= 1 then return end
    if love.touch and #love.touch.getTouches() > 0 then return end
    noteFinger(true, gx, gy)
end

-- === 绘制 ===
local function drawRuntimeItem(label, value, x, y, width)
    color("mint", 0.72)
    love.graphics.setFont(fonts[9])
    love.graphics.print(label, x, y)
    color("cream")
    love.graphics.setFont(fonts[11])
    local text = tostring(value or "unknown")
    if #text > width then text = text:sub(1, width - 3) .. "..." end
    love.graphics.print(text, x, y + 12)
end

local function drawRuntimePanel()
    drawRoundedBox(12, 62, 616, 88, 12, "ink", 0.9)
    color("gold")
    love.graphics.setFont(fonts[10])
    love.graphics.print("RUNTIME", 24, 70)
    drawRuntimeItem("OS", runtime.os, 24, 90, 18)
    drawRuntimeItem("RENDERER", runtime.renderer, 172, 90, 26)
    drawRuntimeItem("GPU", runtime.gpu, 360, 90, 22)
    drawRuntimeItem("INPUT", runtime.input, 24, 122, 18)
    drawRuntimeItem("OUTPUT", runtime.output, 172, 122, 30)
    drawRuntimeItem("LUA", runtime.lua, 360, 122, 22)
end

local function drawInputPanel()
    local age = time - lastInput.time
    local alpha = math.max(0.35, 1 - age * 0.5)
    drawRoundedBox(12, 156, 616, 50, 12, "ink", 0.9)
    color("gold")
    love.graphics.setFont(fonts[10])
    love.graphics.print("LAST INPUT", 24, 163)
    color("mint", 0.72)
    love.graphics.setFont(fonts[9])
    love.graphics.print("TYPE", 24, 180)
    love.graphics.print("CODE", 150, 180)
    love.graphics.print("NAME", 250, 180)
    love.graphics.print("NET", 500, 180)
    color("cream", alpha)
    love.graphics.setFont(fonts[12])
    love.graphics.print(lastInput.type, 24, 188)
    love.graphics.print(lastInput.code, 150, 188)
    love.graphics.print(lastInput.name, 250, 188)
    if net.state == "online" then
        color("mint")
    elseif net.state == "checking" then
        color("gold")
    else
        color("pink")
    end
    love.graphics.setFont(fonts[10])
    love.graphics.print(net.state .. " · " .. net.detail, 500, 190)
end

local function drawSetupPanel()
    drawRoundedBox(12, 156, 616, 50, 12, "ink", 0.9)
    color("gold")
    love.graphics.setFont(fonts[10])
    love.graphics.print("SETUP", 24, 163)
    color("cream")
    love.graphics.setFont(fonts[20])
    love.graphics.print(serverRow.setup.token, 84, 168)
    color("mint", 0.9)
    local urlFont = fonts[12]
    love.graphics.setFont(urlFont)
    local urlX = math.max(176, 84 + fonts[20]:getWidth(serverRow.setup.token) + 16)
    local _, urlLines = urlFont:getWrap(serverRow.setup.url, math.max(40, 616 - urlX))
    love.graphics.print(urlLines[1] or "", urlX, 176)
end

local function drawInputOrSetup()
    if serverRow.setup then drawSetupPanel() else drawInputPanel() end
end

local function drawSky()
    color("sky")
    love.graphics.rectangle("fill", 0, 0, W, H)
    color("sky2", 0.5)
    love.graphics.circle("fill", 560, 40, 120)
    love.graphics.circle("fill", 80, 470, 150)
end

local function drawHint()
    color("cream", 0.7)
    love.graphics.setFont(fonts[9])
    local hint
    if serverRow.holdChat then
        hint = "WAIT  ·  CHAT HELD"
    elseif aid.hasLog() then
        hint = "D-PAD UP  OLDER   ·   D-PAD DOWN  NEWER   ·   HOLD R1 TALK   ·   SELECT QUIT"
    else
        hint = "HOLD R1 TALK  ·  B NET  ·  SELECT QUIT"
    end
    love.graphics.printf(hint, 0, H - 16, W, "center")
end

local MIC_FLOOR_DB = -60
local function dbToFraction(db)
    return math.max(0, math.min(1, (db - MIC_FLOOR_DB) / -MIC_FLOOR_DB))
end

-- 只在第二块屏上画：麦克风波形、电平表、按键录音状态
local drawSttLine
local function drawMicPanel()
    local x, y, w, h = 12, 300, 616, 158
    local live, rec = micwave.isLive(), micwave.recording
    drawRoundedBox(x, y, w, h, 12, "ink", 0.9)
    if rec then
        color("pink", 0.6 + 0.4 * math.sin(love.timer.getTime() * 8))
        love.graphics.setLineWidth(3)
        love.graphics.rectangle("line", x + 1.5, y + 1.5, w - 3, h - 3, 12, 12)
        love.graphics.setLineWidth(1)
    end

    color("gold")
    love.graphics.setFont(fonts[10])
    love.graphics.print("MIC", 24, 308)
    if rec then
        drawRoundedBox(58, 304, 190, 18, 9, "pink")
        color("ink")
        love.graphics.circle("fill", 69, 313, 4)
        love.graphics.setFont(fonts[11])
        love.graphics.print(string.format("REC  %4.1f s / %d s", micwave.recSeconds, micwave.maxClipSeconds), 79, 306)
        color("pink")
        love.graphics.setFont(fonts[9])
        love.graphics.print(ptt.bgmPaused and "music paused · sfx muted" or "sfx muted", 256, 309)
    else
        love.graphics.setFont(fonts[9])
        if live then color("mint", 0.85) else color("pink") end
        local text = live and micwave.detail or ("off · " .. tostring(micwave.detail))
        if #text > 44 then text = text:sub(1, 41) .. "..." end
        love.graphics.print(text, 62, 309)
    end

    local mx, my, mw, mh = 360, 309, 200, 9
    drawRoundedBox(mx, my, mw, mh, 3, "sky2", 0.9)
    if live then
        local level = micwave.rmsDb
        if level > -6 then color("pink") elseif level > -18 then color("gold") else color("mint") end
        love.graphics.rectangle("fill", mx, my, mw * dbToFraction(level), mh, 3, 3)
        color("cream")
        local hx = mx + mw * dbToFraction(micwave.holdDb)
        love.graphics.rectangle("fill", hx - 1, my - 2, 2, mh + 4)
    end
    color("cream", 0.25)
    for _, db in ipairs({-40, -20}) do
        local tx = mx + mw * dbToFraction(db)
        love.graphics.line(tx, my + mh + 1, tx, my + mh + 4)
    end
    color("cream", live and 0.9 or 0.4)
    love.graphics.setFont(fonts[9])
    love.graphics.printf(live and string.format("%.0f dB", micwave.rmsDb) or "-- dB", mx + mw + 4, 308, 52, "right")

    local showAi = aid.active()
    local wx, wy, ww, wh = 24, 326, 592, showAi and 40 or 78
    color("sky2", 0.35)
    love.graphics.rectangle("fill", wx, wy, ww, wh, 6, 6)
    color("cream", 0.12)
    love.graphics.line(wx, wy + wh / 2, wx + ww, wy + wh / 2)
    if rec then color("pink") elseif live then color("mint", 0.9) else color("purple", 0.5) end
    micwave.drawWave(wx, wy, ww, wh)
    if live then
        color("mint", 0.55)
        love.graphics.setFont(fonts[8])
        love.graphics.printf(string.format("x%.0f", micwave.gain), wx, wy + wh - 11, ww - 4, "right")
    elseif not showAi then
        color("pink")
        love.graphics.setFont(fonts[16])
        love.graphics.printf("MIC off", wx, wy + wh / 2 - 22, ww, "center")
        color("cream", 0.7)
        love.graphics.setFont(fonts[10])
        love.graphics.printf(tostring(micwave.detail), wx, wy + wh / 2 + 2, ww, "center")
    end

    if showAi then
        drawSttLine(24, 370, 592, 82, rec, true)
    else
        drawSttLine(24, 410, 592, 44, rec, false)
    end
end

-- 麦克风面板底部：识别中画 …，完成后留下文字和语言。
local function printWrapped(font, text, x, y, limit, maxLines)
    love.graphics.setFont(font)
    local _, wrapped = font:getWrap(text, limit)
    local n = math.min(maxLines, #wrapped)
    local h = font:getHeight()
    for i = 1, n do
        love.graphics.print(wrapped[i], x, y + (i - 1) * h)
    end
    return n
end

local function drawAidBody(x, y, w)
    local tool = aid.toolText(aid.activity)
    if aid.phase == "thinking" then
        color("gold")
        love.graphics.setFont(fonts[11])
        love.graphics.print("AI", x, y + 2)
        if tool then
            printWrapped(fonts.cjk or fonts[11], tool, x + 28, y + 2, w - 28, 1)
        else
            love.graphics.setFont(fonts.cjk or fonts[16])
            love.graphics.print(fonts.cjk and "…" or "...", x + 28, y)
        end
    elseif aid.phase == "error" then
        color("pink")
        love.graphics.setFont(fonts[11])
        love.graphics.printf(aid.detail ~= "" and aid.detail or "AI unavailable", x, y, w, "left")
        if aid.reply ~= "" then
            color("cream", 0.85)
            printWrapped(fonts.cjk or fonts[14], aid.reply, x, y + 16, w, 2)
        end
    elseif tool or aid.reply ~= "" then
        color("gold")
        love.graphics.setFont(fonts[11])
        love.graphics.print("AI", x, y + 2)
        local textY = y
        if tool then
            printWrapped(fonts.cjk or fonts[11], tool, x + 28, y + 2, w - 28, 1)
            textY = y + 16
        end
        if aid.reply ~= "" then
            color("cream")
            printWrapped(fonts.cjk or fonts[14], aid.reply, x + 28, textY, w - 28, tool and 1 or 2)
        end
    end
end

function drawSttLine(x, y, w, h, rec, showAi)
    if rec then
        color("cream", 0.6)
        love.graphics.setFont(fonts[9])
        love.graphics.print("release R1 to stop", x, y + 12)
        return
    end
    if stt.phase == "busy" or (stt.phase == "loading" and stt.pending > 0) then
        color("gold")
        love.graphics.setFont(fonts.cjk or fonts[16])
        love.graphics.print(fonts.cjk and "…" or "...", x, y + 4)
        if micwave.clipNotice then
            color("cream", 0.7)
            love.graphics.setFont(fonts[9])
            love.graphics.printf(micwave.clipNotice, x, y + 14, w, "right")
        end
        return
    end
    if stt.phase == "error" then
        color("pink")
        love.graphics.setFont(fonts[9])
        love.graphics.printf("speech-to-text off  ·  " .. stt.detail, x, y + 8, w, "left")
        return
    end
    if stt.phase == "loading" then
        color("gold")
        love.graphics.setFont(fonts[9])
        love.graphics.print("speech-to-text loading...", x, y + 12)
        return
    end
    if stt.text and stt.text ~= "" then
        local font = fonts.cjk or fonts[14]
        local textX = x
        if stt.lang and stt.lang ~= "" then
            color("gold")
            love.graphics.setFont(fonts[11])
            love.graphics.print(stt.lang, x, y + 2)
            textX = x + 36
        end
        color("cream", showAi and 0.55 or 1)
        printWrapped(font, stt.text, textX, y, w - (textX - x), showAi and 1 or 2)
        if showAi then drawAidBody(x, y + 22, w) end
        return
    end
    if showAi and aid.phase == "error" and aid.detail ~= "" then
        color("pink")
        love.graphics.setFont(fonts[11])
        love.graphics.printf(aid.detail, x, y + 8, w, "left")
        return
    end
    color("cream", 0.6)
    love.graphics.setFont(fonts[9])
    love.graphics.print("hold R1 (or t) to record a clip", x, y + 12)
end

local function drawChatLog()
    layoutChat()
    local x, y, w, h = 12, 64, CHAT_W, CHAT_H
    drawRoundedBox(x, y, w, h, 12, "ink", 0.9)
    local font = fonts.cjk or fonts[16]
    if not font then return end
    local lh = font:getHeight()
    local innerX, innerY = x + 10, y + 10
    local innerW, innerH = w - 20, h - 20
    if serverRow.setup then
        color("gold")
        love.graphics.setFont(fonts[12])
        love.graphics.print(serverRow.setup.token, innerX, innerY)
        color("cream", 0.9)
        local urlFont = fonts[11]
        love.graphics.setFont(urlFont)
        local room = math.max(20, innerW - fonts[12]:getWidth(serverRow.setup.token) - 16)
        local _, urlLines = urlFont:getWrap(serverRow.setup.url, room)
        love.graphics.print(urlLines[1] or "", innerX + fonts[12]:getWidth(serverRow.setup.token) + 12, innerY + 1)
        innerY = innerY + 18
        innerH = innerH - 18
    end
    love.graphics.push("all")
    love.graphics.setScissor(innerX, innerY, innerW - 8, innerH)
    love.graphics.setFont(font)
    local first = chatScroll + 1
    local last = math.min(#chatLines, first + chatView - 1)
    for i = first, last do
        local line = chatLines[i]
        local ly = innerY + (i - first) * lh
        if line.tag then
            color("gold")
            love.graphics.print(line.tag, innerX, ly)
            color(line.color or "cream", line.alpha or 1)
            love.graphics.print(line.text, innerX + line.tagW, ly)
        elseif not line.gap then
            local indent = line.tagW or 0
            color(line.color or "cream", line.alpha or 1)
            love.graphics.print(line.text, innerX + indent, ly)
        end
    end
    love.graphics.pop()
    if chatMax > 0 then
        local trackX = x + w - 8
        local barH = math.max(16, (chatView / #chatLines) * innerH)
        local barY = innerY + (chatScroll / chatMax) * (innerH - barH)
        color("cream", 0.2)
        love.graphics.rectangle("fill", trackX, innerY, 3, innerH, 1, 1)
        color("gold", chatStick and 0.55 or 0.95)
        love.graphics.rectangle("fill", trackX, barY, 3, barH, 1, 1)
    end
end

local function drawMicStrip()
    local x, y, w, h = 12, 390, 616, 72
    local live, rec = micwave.isLive(), micwave.recording
    drawRoundedBox(x, y, w, h, 12, "ink", 0.9)
    if rec then
        color("pink", 0.6 + 0.4 * math.sin(love.timer.getTime() * 8))
        love.graphics.setLineWidth(3)
        love.graphics.rectangle("line", x + 1.5, y + 1.5, w - 3, h - 3, 12, 12)
        love.graphics.setLineWidth(1)
    end
    color("gold")
    love.graphics.setFont(fonts[10])
    local label = rec and string.format("REC %3.1fs", micwave.recSeconds) or "MIC"
    love.graphics.print(label, 24, y + 8)
    local wx, wy, ww, wh = 130, y + 28, 470, 36
    color("sky2", 0.35)
    love.graphics.rectangle("fill", wx, wy, ww, wh, 6, 6)
    if rec then color("pink") elseif live then color("mint", 0.9) else color("purple", 0.5) end
    micwave.drawWave(wx, wy, ww, wh)
end

local function drawServerRow()
    local button = serverTargets()[1]
    local x, y, w, h = 12, 8, 616, 48
    drawRoundedBox(x, y, w, h, 12, "ink", 0.9)
    local wordColor = "gold"
    if serverRow.state == "failed" or serverRow.state == "auth" then
        wordColor = "pink"
    elseif serverRow.state == "running" then
        wordColor = "mint"
    end
    color(wordColor)
    love.graphics.setFont(fonts[14])
    love.graphics.print(serverRow.word or "", x + 14, y + 6)
    local reserve = 0
    if button then
        local font = fonts[14]
        love.graphics.setFont(font)
        local label = button.label
        local lw = font:getWidth(label)
        reserve = lw + 36
        local tx = button.x + button.w - lw - 16
        local ty = button.y + (button.h - font:getHeight()) / 2
        drawRoundedBox(tx - 12, button.y + 8, lw + 24, button.h - 16, 8, "gold", 1)
        color("ink")
        love.graphics.print(label, tx, ty)
    end
    local detail = serverRow.detail or ""
    local font = fonts[11]
    love.graphics.setFont(font)
    local limit = math.max(40, w - 28 - reserve)
    if serverRow.log and font:getWidth(detail .. "  " .. serverRow.log) <= limit then
        detail = detail .. "  " .. serverRow.log
    end
    color("cream", 0.9)
    local _, lines = font:getWrap(detail, limit)
    love.graphics.print(lines[1] or "", x + 14, y + 26)
end

local function drawInfoScreen()
    drawSky()
    drawServerRow()
    if aid.hasLog() then
        drawChatLog()
        drawMicStrip()
    else
        drawRuntimePanel()
        drawInputOrSetup()
        drawMicPanel()
    end
    drawHint()
end

function love.draw()
    drawInfoScreen()

    if shutdownDialog then
        color("ink", 0.7)
        love.graphics.rectangle("fill", 0, 0, W, H)
        drawRoundedBox(190, 176, 260, 110, 16, "ink", 1)
        color("gold")
        love.graphics.setFont(fonts[22])
        love.graphics.printf("SHUTDOWN?", 0, 196, W, "center")
        color("cream")
        love.graphics.setFont(fonts[11])
        love.graphics.printf("A confirm  /  B cancel", 0, 234, W, "center")
    end

    if hud.external then
        subscreen.present(function() end)
    end

    if selftest then
        drawSelftest()
    end
end

-- === 自检模式 ===
local selftestDone = false
local selftestStart = 0

function drawSelftest()
    if selftestStart == 0 then selftestStart = love.timer.getTime() end
    local elapsed = love.timer.getTime() - selftestStart
    if selftestDone or elapsed < 1.5 then return end
    if netProbe and elapsed < NET_WATCHDOG + 1 then return end
    selftestDone = true

    local joysticks = love.joystick.getJoysticks()
    local j = joysticks[1]
    local lines = {}
    local function add(k, v) lines[#lines + 1] = string.format("%-10s %s", k, tostring(v)) end

    add("love", table.concat({love.getVersion()}, "."))
    add("os", runtime.os)
    add("renderer", runtime.renderer)
    add("gpu", runtime.gpu)
    add("output", runtime.output)
    add("fps", love.timer.getFPS())
    add("pad", j and j:getName() or "none")
    if j then
        add("buttons", j:getButtonCount())
        add("axes", j:getAxisCount())
        add("hats", j:getHatCount())
        add("hat1", j:getHat(1))
        add("guid", j:getGUID())
    end
    add("audio", audio.enabled and "enabled (playback device open)" or ("unavailable: " .. tostring(audio.error)))
    add("net", net.state .. " " .. net.detail)
    add("mic", string.format("%s (%s), rms %.0f dBFS", micwave.state, tostring(micwave.detail), micwave.rmsDb))
    add("stt", stt.phase .. (stt.detail ~= "" and (" (" .. stt.detail .. ")") or ""))
    add("aid", aid.phase .. (aid.detail ~= "" and (" (" .. aid.detail .. ")") or ""))
    add("server", (serverRow.word or "") .. (serverRow.action and (" · " .. serverRow.action) or ""))
    add("subscreen", hud.external and string.format("second window on display %d, %d frames", subscreen.display, subscreen.frames)
        or ("off: " .. tostring(hud.error)))
    add("mem KB", string.format("%.0f", collectgarbage("count")))

    local report = table.concat(lines, "\n") .. "\n"
    io.write("\n=== SELFTEST ===\n" .. report .. "=== END ===\n")
    io.stdout:flush()
    love.filesystem.write("selftest.txt", report)

    if inputlog then
        -- 自检 + 输入日志：报告后继续运行，等待人工按键
        selftestDone = false
        selftestStart = love.timer.getTime() - 1000
        return
    end
    love.event.quit()
end
