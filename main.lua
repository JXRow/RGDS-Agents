-- RGDS-Agents (Anbernic RG DS) LÖVE 演示
-- 移植自 rg34xx-lua-app：分辨率 720x480 -> 640x480，按键表换成 RK3568 拓扑，
-- 新增触摸显示、网络探测，以及 --selftest / --inputlog 两个验证模式。
-- fixed 版：网络探测改为 love.thread 后台执行不卡帧；自检如实报告音频是否真的拿到播放设备。
-- v2：标题/分数/RUNTIME/LAST INPUT 信息面板移到第二块屏（见 subscreen.lua），主屏只剩游戏；
--     开不了第二个窗口时退回原来的单屏布局。
--     信息面板加麦克风实时波形与电平（micwave.lua / micthread.lua，经 dsnoop 共享录音）；
--     按住 R1（键盘 t）录一段语音，录音期间暂停 BGM。松开后把这段已经录好的音频
--     交给常驻的 sv-helper（stt.lua）做离线识别，信息面板留下文字和语言，
--     主屏顶部同时显示约 5 秒。识别出文字后再交给 rgds-aid（MiniMax，仍在本机），
--     回复留在信息面板，长回复在这块屏上换行，十字键上下滚动；流式输出时跟着最新一行。
--     主屏只留开头一两行，大约 5 秒。语音识别保持离线。
--     助手、密钥或网络挂了，游戏照常跑，信息面板写明原因。

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

-- 下屏 UI 按钮(触摸坐标即信息面板像素,GT911 直读)
local recBtn = {x = 12, y = 390, w = 616, h = 72}   -- MIC 条整条作"按住说话"触摸按钮
local exitBtn = {x = 588, y = 6, w = 40, h = 40}    -- 右上角 ✕

local function inRect(b, x, y)
    return x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h
end

-- 关闭按钮符号用两条斜线画,避免字体缺字形显示成方块
local function drawXMark(b)
    local cx, cy, r = b.x + b.w / 2, b.y + b.h / 2, 9
    love.graphics.setLineWidth(3)
    love.graphics.line(cx - r, cy - r, cx + r, cy + r)
    love.graphics.line(cx - r, cy + r, cx + r, cy - r)
    love.graphics.setLineWidth(1)
end
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
local touchpoll = require("touchpoll")
local evdev = require("evdev")
local hud = {external = false, error = nil}

-- 伴生模式(RGDS_AGENTS_COMPANION=1):与 RGDS-SORX 同时启动。藏掉主窗口把上屏
-- 让给游戏,只留下屏对话面板;STT 模型延迟到第一次按 R1 才加载(省开局 CPU/内存)。
local companion = os.getenv("RGDS_AGENTS_COMPANION") == "1"
local sttLazy, sttLazyStarted = companion, false

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
    if ptt.held or shutdownDialog then return end
    -- 伴生模式:STT 模型(229MB,设备上加载约 21s)延迟到第一次按 R1 才加载,
    -- 避免跟游戏抢开局 CPU/内存;此后常驻
    if sttLazy and not sttLazyStarted then
        sttLazyStarted = true
        stt.start()
    end
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

-- 下屏触摸(GT911 I2C 直读,Weston 不派发):命中 UI 按钮等效按键。
-- 按住 MIC 条 = R1 按住说话;点右上角 ✕ = R2 退出。
local touchFinger = nil       -- {x, y, down} 最近的手指点
local touchHeldPtt = false   -- 手指正按在录音按钮上

local function noteTouch(phase, x, y)
    if phase == "move" then
        if touchFinger then touchFinger.x, touchFinger.y = x, y end
        return
    end
    if phase == true then
        touchFinger = {x = x, y = y, down = true}
        print(string.format("touch: info %.0f,%.0f", x, y))
        io.stdout:flush()
        if inRect(exitBtn, x, y) then
            love.event.push("quit")
        elseif inRect(recBtn, x, y) and not ptt.held then
            touchHeldPtt = true
            pttPress()
        end
    else
        if touchFinger then touchFinger.down = false end
        if touchHeldPtt then
            touchHeldPtt = false
            pttRelease()
        end
    end
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

function love.load()
    love.graphics.setDefaultFilter("nearest", "nearest")
    for _, size in ipairs({8, 9, 10, 11, 12, 14, 16, 20, 22, 28}) do
        fonts[size] = love.graphics.newFont(size)
    end
    fonts.cjk = loadCjkFont(16)

    for _, value in ipairs(arg or {}) do
        if value == "--selftest" then selftest = true end
        if value == "--inputlog" then inputlog = true end
        if value == "--shot" then shotRequested = true end
        if value == "--one-screen" then hud.error = "disabled by --one-screen" end
    end

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
    if companion then
        print("companion: STT deferred until first R1 press (RGDS_AGENTS_COMPANION=1)")
    else
        stt.start()
    end
    aid.start()
    windowW, windowH = love.graphics.getWidth(), love.graphics.getHeight()

    if not hud.error and not love.window.isVisible() then hud.error = "main window hidden" end
    if not hud.error then
        local ok, err = subscreen.open(W, H)
        hud.external, hud.error = ok, err
    end
    if hud.external then
        setFieldTop(0)
        print(string.format("subscreen: info pane on display %d (main window on display %d)",
            subscreen.display, subscreen.mainDisplay))
        if companion then
            -- 上屏全让给游戏:藏掉主窗口。手柄键经 evdev/js0 直达 LÖVE,不依赖窗口焦点
            if subscreen.hideMainWindow() then
                print("companion: main window hidden, upper screen free for the game")
            end
        end
    else
        print("subscreen: off (" .. tostring(hud.error) .. "), info pane stays on the main screen")
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
        output = hud.external and string.format("%d x %d + info on display %d", windowW, windowH, subscreen.display)
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

    -- 下屏触摸:Weston 不把 gt9xx-0 派发给 SDL,后台线程直读 GT911 I2C 寄存器。
    -- evdev(event1)一并打开:驱动当前不写事件,留作驱动修好后的通路。
    local tpOk, tpErr = touchpoll.open(noteTouch)
    print("touchpoll: " .. (tpOk and "gt911 poller started" or ("off (" .. tostring(tpErr) .. ")")))
    local evOk, evErr = evdev.open(nil, W, H, noteTouch)
    if not evOk then print("evdev: off (" .. tostring(evErr) .. ")") end
    io.stdout:flush()

    if selftest then
        love.filesystem.write("selftest.txt", "")
        probeNet()
        love.timer.sleep(1.2)     -- 让帧率统计稳定
        return
    end
    probeNet()
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
local chatOverflow = false
local scrollArm = nil

local function layoutChat()
    chatLines = {}
    chatOverflow = false
    chatMax = 0
    if not aid.hasLog() then return end
    local font = fonts.cjk or fonts[16]
    if not font then return end
    love.graphics.setFont(font)
    local lh = font:getHeight()
    chatView = math.max(1, math.floor((CHAT_H - 20) / lh))
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
            local tag = (turn.lang and turn.lang ~= "" and turn.lang or "YOU") .. "  "
            pushWrapped(tag, turn.text, "cream", 0.62)
        else
            local body = turn.text
            if body == "" and turn.live then body = fonts.cjk and "…" or "..." end
            pushWrapped("AI  ", body, "cream", 1)
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
    touchpoll.pump()
    evdev.pump()
    pollNet(dt)
    micwave.update(dt)
    stt.update()
    if stt.serial ~= aidSeen then
        aidSeen = stt.serial
        if stt.text and stt.text ~= "" then aid.chat(stt.text, stt.lang) end
    end
    aid.update()
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
    -- 标题画面原本降到 ~6 fps 省电；麦克风在线或手指按下时不睡(波形/触摸要实时)
    if not started and not micwave.isLive() and not (touchFinger and touchFinger.down) then
        love.timer.sleep(0.15)
    end

    time = time + dt
    pulse = math.max(0, pulse - dt)

    for _, petal in ipairs(petals) do
        petal.y = petal.y + petal.speed * dt
        petal.x = petal.x + math.sin(time * 0.7 + petal.drift) * 8 * dt
        if petal.y > H + 8 then
            petal.y = FIELD_TOP
            petal.x = math.random() * W
        end
    end

    for i = #sparks, 1, -1 do
        local spark = sparks[i]
        spark.x = spark.x + spark.vx * dt
        spark.y = spark.y + spark.vy * dt
        spark.vy = spark.vy + 150 * dt
        spark.life = spark.life - dt
        if spark.life <= 0 then table.remove(sparks, i) end
    end

    local dx, dy = 0, 0
    local lockV = pollChatScroll()
    local joystick = love.joystick.getJoysticks()[1]
    if joystick then
        local hat = joystick:getHat(1)
        -- hat 优先；只有 hat 归中时才看左摇杆，避免轴上 0 值覆盖 hat（RG 系列通用坑）
        -- 回复比信息屏高时，上/下改成滚动，左/右仍走路
        if hat and hat ~= "c" and hat ~= "" then
            if not lockV and hat:find("u") then dy = dy - 1 end
            if not lockV and hat:find("d") then dy = dy + 1 end
            if hat:find("l") then dx = dx - 1 end
            if hat:find("r") then dx = dx + 1 end
        else
            local jx, jy = joystick:getGamepadAxis("leftx"), joystick:getGamepadAxis("lefty")
            if jx and math.abs(jx) > 0.18 then dx = jx end
            if jy and math.abs(jy) > 0.18 and not lockV then dy = jy end
        end
    end
    if isDown({"left", "a"}) then dx = dx - 1 end
    if isDown({"right", "d"}) then dx = dx + 1 end
    if not lockV and isDown({"up", "w"}) then dy = dy - 1 end
    if not lockV and isDown({"down", "s"}) then dy = dy + 1 end

    local length = math.sqrt(dx * dx + dy * dy)
    if length > 1 then dx, dy = dx / length, dy / length end
    player.x = math.max(32, math.min(W - 32, player.x + dx * player.speed * dt))
    player.y = math.max(PLAYER_MIN_Y, math.min(PLAYER_MAX_Y, player.y + dy * player.speed * dt))

    table.insert(player.trail, 1, {x = player.x, y = player.y, life = 0.28})
    if #player.trail > 12 then table.remove(player.trail) end
    for _, point in ipairs(player.trail) do point.life = point.life - dt end

    local distance = math.sqrt((player.x - seed.x) ^ 2 + (player.y - seed.y) ^ 2)
    if distance < player.r + 16 then
        score = score + 1
        best = math.max(best, score)
        pulse = 0.5
        addSpark(seed.x, seed.y, 16)
        spawnSeed()
        playSfx("collect")
    end
end

function love.keypressed(key, scancode)
    recordInput("keypressed", scancode or key, key)
    if key == "escape" then love.event.quit() end
    if key == "space" or key == "return" or key == "kpenter" then
        if not started then
            started = true
            playSfx("start")
            startBgm()
        else
            playSfx("start")
        end
    end
    if key == "r" then reset(); playSfx("reset") end
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
    if button == 1 or button == 8 then          -- A / START
        if not started then
            started = true
            playSfx("start")
            startBgm()
        end
    elseif button == 2 then                     -- B
        probeNet()
    elseif button == 7 then                     -- SELECT
        pttRelease()
        shutdownDialog = true
    elseif button == PTT_BUTTON then
        pttPress()
    elseif button == 12 then                    -- R2:退出应用(与右上角 ✕ 等效)
        love.event.push("quit")
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
    recordInput("touch", id, string.format("%.0f,%0.f", x, y))
    if inRect(exitBtn, x, y) then love.event.push("quit") end
end

function love.mousepressed(x, y, button)
    recordInput("mouse", button, string.format("%.0f,%0.f", x, y))
    if button == 1 and inRect(exitBtn, x, y) then love.event.push("quit") end
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

local function drawGame()
    color("grass")
    love.graphics.rectangle("fill", 0, FIELD_TOP, W, H - FIELD_TOP)
    color("grass2", 0.45)
    for x = -30, W, 52 do
        love.graphics.line(x, FIELD_TOP, x + 200, H)
    end
    for y = FIELD_TOP + 40, H, 42 do
        love.graphics.line(0, y, W, y - 110)
    end

    for _, spark in ipairs(sparks) do
        color("gold", math.min(1, spark.life * 2))
        love.graphics.circle("fill", spark.x, spark.y, spark.size)
    end

    local seedBob = math.sin(time * 3 + seed.phase) * 5
    color("pink", 0.16)
    love.graphics.circle("fill", seed.x, seed.y + seedBob, 28 + math.sin(time * 4) * 3)
    color("pink")
    love.graphics.circle("fill", seed.x, seed.y + seedBob, 11)
    color("cream")
    love.graphics.circle("fill", seed.x - 6, seed.y - 2 + seedBob, 4)
    love.graphics.circle("fill", seed.x + 6, seed.y - 2 + seedBob, 4)
    color("gold")
    love.graphics.circle("fill", seed.x, seed.y + 7 + seedBob, 3.5)

    for _, point in ipairs(player.trail) do
        if point.life > 0 then
            color("mint", point.life * 0.3)
            love.graphics.circle("fill", point.x, point.y, 5)
        end
    end

    color("ink", 0.35)
    love.graphics.ellipse("fill", player.x, player.y + 20, 20, 7)
    color("mint")
    love.graphics.circle("fill", player.x, player.y, player.r)
    color("cream")
    love.graphics.circle("fill", player.x - 5, player.y - 4, 3.5)
    love.graphics.circle("fill", player.x + 5, player.y - 4, 3.5)
    color("ink")
    love.graphics.circle("fill", player.x - 5, player.y - 4, 1.6)
    love.graphics.circle("fill", player.x + 5, player.y - 4, 1.6)
    love.graphics.arc("line", "open", player.x - 6, player.y + 1, 6, 0.2, math.pi - 0.2)

    if pulse > 0 then
        color("gold", pulse * 0.5)
        love.graphics.circle("line", seed.x, seed.y, 28 + (0.5 - pulse) * 50)
    end
end

local function drawSky()
    color("sky")
    love.graphics.rectangle("fill", 0, 0, W, H)
    color("sky2", 0.5)
    love.graphics.circle("fill", 560, 40, 120)
    love.graphics.circle("fill", 80, 470, 150)
end

local function drawHeader()
    color("cream")
    love.graphics.setFont(fonts[22])
    love.graphics.print("RGDS-AGENTS", 14, 14)
    if fonts.cjk then
        color("mint", 0.75)
        love.graphics.setFont(fonts.cjk)
        love.graphics.print("AI 对话 · v2", 16, 40)
    else
        color("mint", 0.75)
        love.graphics.setFont(fonts[10])
        love.graphics.print("AI CHAT · v2", 16, 42)
    end
    color("gold", 0.85)
    love.graphics.setFont(fonts[9])
    love.graphics.print(string.format("FPS %02d · MEM %.1f MB · SND %s · MIC %s", love.timer.getFPS(),
        collectgarbage("count") / 1024, audio.enabled and "on" or "off",
        micwave.recording and "REC" or (micwave.isLive() and "live" or "off")), 210, 42)

    -- 右上角关闭按钮:点击(触摸/鼠标)或按 R2 退出应用,回 MUOS 菜单
    drawRoundedBox(exitBtn.x, exitBtn.y, exitBtn.w, exitBtn.h, 10, "ink", 0.72)
    color("cream")
    drawXMark(exitBtn)
end

local function drawHint(info)
    color("cream", 0.7)
    love.graphics.setFont(fonts[9])
    local hint
    if info and aid.hasLog() then
        hint = "D-PAD UP/DOWN SCROLL   ·   HOLD R1 OR TOUCH REC TO TALK   ·   R2 / X-EXIT"
    elseif hud.external then
        hint = "HAT MOVE  ·  A START  ·  B NET  ·  HOLD R1 TALK  ·  R2 / X-EXIT  ·  R RESTART"
    else
        hint = "HAT MOVE  ·  A START  ·  B NET  ·  SELECT QUIT  ·  R RESTART"
    end
    love.graphics.printf(hint, 0, H - 16, W, "center")
end

-- 只在第二块屏上画：游玩状态，逐帧刷新
local function drawStatusPanel()
    drawRoundedBox(12, 212, 616, 82, 12, "ink", 0.9)
    color("gold")
    love.graphics.setFont(fonts[10])
    love.graphics.print("GARDEN", 24, 220)
    local state = shutdownDialog and "SHUTDOWN?" or (started and "PLAYING" or "TITLE")
    local bgm = audio.enabled and audio.bgm and audio.bgm:isPlaying()
    drawRuntimeItem("STATE", state, 24, 240, 18)
    drawRuntimeItem("PLAYER", string.format("%3.0f, %3.0f", player.x, player.y), 172, 240, 20)
    drawRuntimeItem("SEED", string.format("%3.0f, %3.0f", seed.x, seed.y), 360, 240, 20)
    drawRuntimeItem("TIME", string.format("%02d:%04.1f", math.floor(time / 60), time % 60), 24, 266, 18)
    drawRuntimeItem("AUDIO", audio.enabled and (bgm and "on · bgm playing" or "on") or "off", 172, 266, 20)
    drawRuntimeItem("FRAME", tostring(subscreen.frames), 360, 266, 20)
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

-- 信息面板底部：识别中画 …，完成后留下文字和语言。FRAME / TIME 在 GARDEN 里，不在这里。
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
    if aid.phase == "thinking" then
        color("gold")
        love.graphics.setFont(fonts.cjk or fonts[16])
        love.graphics.print(fonts.cjk and "…" or "...", x + 28, y)
        color("gold")
        love.graphics.setFont(fonts[11])
        love.graphics.print("AI", x, y + 2)
    elseif aid.phase == "error" then
        color("pink")
        love.graphics.setFont(fonts[11])
        love.graphics.printf(aid.detail ~= "" and aid.detail or "AI unavailable", x, y, w, "left")
        if aid.reply ~= "" then
            color("cream", 0.85)
            printWrapped(fonts.cjk or fonts[14], aid.reply, x, y + 16, w, 2)
        end
    elseif aid.reply ~= "" then
        color("gold")
        love.graphics.setFont(fonts[11])
        love.graphics.print("AI", x, y + 2)
        color("cream")
        printWrapped(fonts.cjk or fonts[14], aid.reply, x + 28, y, w - 28, 2)
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

-- 主屏（DSI-1）顶部一两行，约 5 秒后消失。不挡整块草地。
local function drawSttBanner()
    local text, tag
    if aid.bannerActive() then
        text, tag = aid.bannerText, "AI"
    elseif stt.bannerActive() then
        text, tag = stt.bannerText, stt.bannerLang
    else
        return
    end
    local font = fonts.cjk or fonts[16]
    local hasTag = tag and tag ~= ""
    local textX = hasTag and 64 or 24
    local limit = W - textX - 20
    love.graphics.setFont(font)
    local _, lines = font:getWrap(text, limit)
    local n = math.max(1, math.min(2, #lines))
    local boxH = 10 + n * font:getHeight() + 6
    drawRoundedBox(12, 8, W - 24, boxH, 10, "ink", 0.88)
    if hasTag then
        color("gold")
        love.graphics.setFont(fonts[12])
        love.graphics.print(tag, 24, 14)
    end
    color("cream")
    printWrapped(font, text, textX, 12, limit, 2)
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
    if #chatLines == 0 then
        color("cream", 0.55)
        love.graphics.setFont(font)
        love.graphics.printf("按住 R1 说话，开始对话", x, y + h / 2 - 10, w, "center")
    end
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
    -- 整条 MIC 区即触摸录音按钮(recBtn):按下开始录音,松开发送;R1 同效
    local x, y, w, h = recBtn.x, recBtn.y, recBtn.w, recBtn.h
    local live, rec = micwave.isLive(), micwave.recording
    local pressed = rec or touchHeldPtt
    drawRoundedBox(x, y, w, h, 12, pressed and "sky2" or "ink", 0.9)
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
    if fonts.cjk then
        love.graphics.setFont(fonts.cjk)
        color(rec and "pink" or "cream", 0.95)
        love.graphics.printf(rec and "松开发送" or "按住说话  ·  触摸 / R1", x, y + 6, w, "center")
    end
    local wx, wy, ww, wh = 130, y + 28, 470, 36
    color("sky2", 0.35)
    love.graphics.rectangle("fill", wx, wy, ww, wh, 6, 6)
    if rec then color("pink") elseif live then color("mint", 0.9) else color("purple", 0.5) end
    micwave.drawWave(wx, wy, ww, wh)
end

local function drawInfoScreen()
    -- 阶段二:砍掉开机测试界面(RUNTIME/LAST INPUT/状态面板),直接进 AI 对话框
    drawSky()
    drawHeader()
    drawChatLog()
    drawMicStrip()
    drawHint(true)
end

function love.draw()
    -- 阶段一:砍掉上屏游戏,主窗口(上屏)只留黑屏。
    -- 信息面板照常走下屏副屏窗口;语音管线(mic/stt/aid)的更新在 love.update 里,不受影响。
    love.graphics.clear(0, 0, 0, 1)

    if hud.external then
        subscreen.present(drawInfoScreen)
    else
        drawInfoScreen()
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
    add("subscreen", hud.external and string.format("info pane on display %d, %d frames", subscreen.display, subscreen.frames)
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
