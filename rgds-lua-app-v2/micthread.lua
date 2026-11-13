-- 录音线程（由 micwave.lua 启动）：经 OpenAL 读麦克风，写进和主线程共享的两个环形缓冲。
-- 掌机上启动脚本 export ALSOFT_CONF=alsoft.conf，把 "ALSA Default" 的录音指到 dsnoop（可共享）；
-- 没有它时默认设备是独占的 hw:0,0 且只支持 44.1 kHz，16 kHz 打不开 → 报 error，不去抢设备。
--   pcm  : int16 单声道 16 kHz（左声道 = 机身麦克风），按键录音的片段从这里截取
--   bins : 每 binSamples 个样本一对 (min, max)，已去直流，给波形
-- 写入位置是累计计数，每处理完一块数据后经 Channel 发布；Channel 的互斥锁保证读方看到
-- 计数时对应的数据已写完，所以读方只读 [计数 - 容量, 计数) 范围内的内容即可。
--
-- 按键录音：主线程发 {cmd="clip_start", id} / {cmd="clip_end", id}。片段 = 按下前 prerollSamples
-- 到松开后 tailSamples，最长 maxClipSamples（到上限自动结束）。结果推到 clipChannel：
--   {id, ok=true, sound=SoundData(16 kHz, 16 bit, 单声道), samples, seconds, peak, path, reason}
--   {id, ok=false, reason}
-- 同时写一份 WAV 到存档目录（path，覆盖上一份），供之后的语音识别或人工检查。
require("love.timer")
require("love.data")
require("love.sound")
require("love.audio")
require("love.filesystem")
local ffi = require("ffi")

local pcmData, binData, cfg = ...
local pcm = ffi.cast("int16_t *", pcmData:getFFIPointer())
local bmin = ffi.cast("int16_t *", binData:getFFIPointer())
local bmax = bmin + cfg.binCap
local pcmCap, binCap, binSamples = cfg.pcmCap, cfg.binCap, cfg.binSamples
local posChannel = love.thread.getChannel(cfg.posChannel)
local ctlChannel = love.thread.getChannel(cfg.ctlChannel)
local clipChannel = love.thread.getChannel(cfg.clipChannel)

local pcmPos, binPos = 0, 0
local accMin, accMax, accN = math.huge, -math.huge, 0
local dc = 0
local detail = ""
local state = "starting"
local lastRms, lastPeak = 0, 0
local clip = nil      -- {id, start, stopAt}

local function publish(newState, text)
    if newState then state, detail = newState, text end
    local t = {state = state, detail = detail, pcm = pcmPos, bins = binPos, rms = lastRms, peak = lastPeak,
        rec = clip ~= nil, recSamples = clip and (pcmPos - clip.start) or 0}
    posChannel:performAtomic(function(ch)
        ch:clear()
        ch:push(t)
    end)
end

local function clamp16(v)
    if v > 32767 then return 32767 elseif v < -32768 then return -32768 end
    return v
end

local function consume(sd, channels)
    local n = sd:getSampleCount()
    if n <= 0 then return end
    local p = ffi.cast("const int16_t *", sd:getFFIPointer())
    local sumsq, peak = 0, 0
    for i = 0, n - 1 do
        local x = p[i * channels]
        pcm[(pcmPos + i) % pcmCap] = x
        dc = dc + (x - dc) * 0.0005
        local y = x - dc
        sumsq = sumsq + y * y
        if y > peak then peak = y elseif -y > peak then peak = -y end
        if y < accMin then accMin = y end
        if y > accMax then accMax = y end
        accN = accN + 1
        if accN == binSamples then
            local j = binPos % binCap
            bmin[j] = clamp16(accMin)
            bmax[j] = clamp16(accMax)
            binPos = binPos + 1
            accMin, accMax, accN = math.huge, -math.huge, 0
        end
    end
    pcmPos = pcmPos + n
    lastRms, lastPeak = math.sqrt(sumsq / n), peak
end

local function wavHeader(samples)
    local bytes = samples * 2
    return love.data.pack("string", "<c4I4c4c4I4I2I2I4I4I2I2c4I4",
        "RIFF", 36 + bytes, "WAVE", "fmt ", 16, 1, 1, cfg.rate, cfg.rate * 2, 2, 16, "data", bytes)
end

local function finishClip(reason)
    local c = clip
    clip = nil
    local first = math.max(c.start, pcmPos - pcmCap)
    local last = math.min(pcmPos, c.stopAt or pcmPos)
    local n = last - first
    if n < cfg.minClipSamples then
        clipChannel:push({id = c.id, ok = false, reason = n <= 0 and "no audio" or "too short"})
        return
    end
    local sd = love.sound.newSoundData(n, cfg.rate, 16, 1)
    local dst = ffi.cast("int16_t *", sd:getFFIPointer())
    local peak = 0
    for i = 0, n - 1 do
        local x = pcm[(first + i) % pcmCap]
        dst[i] = x
        if x > peak then peak = x elseif -x > peak then peak = -x end
    end
    local ok = love.filesystem.write(cfg.clipFile, wavHeader(n) .. sd:getString())
    clipChannel:push({id = c.id, ok = true, sound = sd, samples = n, seconds = n / cfg.rate, peak = peak,
        path = ok and (love.filesystem.getSaveDirectory() .. "/" .. cfg.clipFile) or "", reason = reason})
end

local function handleControl(msg)
    if msg == "stop" then return false end
    if type(msg) ~= "table" then return true end
    if msg.cmd == "clip_start" and not clip then
        clip = {id = msg.id, start = math.max(0, pcmPos - cfg.prerollSamples, pcmPos - pcmCap)}
    elseif msg.cmd == "clip_end" and clip and clip.id == msg.id and not clip.stopAt then
        clip.stopAt = pcmPos + cfg.tailSamples
    end
    return true
end

local function checkClip(capturing)
    if not clip then return end
    if pcmPos - clip.start >= cfg.maxClipSamples then
        clip.stopAt = math.min(clip.stopAt or math.huge, clip.start + cfg.maxClipSamples)
        finishClip("max length")
    elseif clip.stopAt and (pcmPos >= clip.stopAt or not capturing) then
        finishClip(capturing and "released" or "capture lost")
    end
end

local function openDevice()
    if cfg.needConf and not os.getenv("ALSOFT_CONF") then
        -- 没有 dsnoop 配置时默认录音设备是 asound.conf 的 hooks → hw:0,0：独占，且打开就会写混音器
        return nil, "ALSOFT_CONF not set (launch via the menu script)"
    end
    local devices = love.audio.getRecordingDevices()
    local dev = devices[1]
    if not dev then return nil, "no capture device" end
    -- 优先立体声取左声道：plug 混成单声道会把麦克风（只在左声道）压低 6 dB
    for _, channels in ipairs({2, 1}) do
        if dev:start(cfg.ringSamples, cfg.rate, 16, channels) then return dev, channels end
    end
    return nil, string.format("%s: cannot open %d Hz capture (busy?)", dev:getName(), cfg.rate)
end

local dev, channels
local retryAt, backoff, lastData = 0, 1, 0
local running = true
publish("starting", "opening mic")

while running do
    local msg = ctlChannel:pop()
    while msg ~= nil and running do
        running = handleControl(msg)
        msg = ctlChannel:pop()
    end
    if not running then break end

    local now = love.timer.getTime()
    if not dev then
        if now >= retryAt then
            local d, chOrErr = openDevice()
            if d then
                dev, channels, lastData, backoff = d, chOrErr, now, 1
                publish("live", string.format("%d Hz · %s", dev:getSampleRate(), dev:getName()))
            else
                publish("error", chOrErr)
                retryAt, backoff = now + backoff, math.min(backoff * 2, 10)
            end
        end
    else
        local sd = dev:getData()
        if sd then
            consume(sd, channels)
            sd:release()
            lastData = now
            publish()
        elseif now - lastData > 1 or not dev:isRecording() then
            dev:stop()
            dev = nil
            lastRms, lastPeak = 0, 0
            publish("error", "capture stalled, reopening")
            retryAt, backoff = now + backoff, math.min(backoff * 2, 10)
        end
    end
    checkClip(dev ~= nil)
    love.timer.sleep(0.01)
end

if dev then dev:stop() end
if clip then
    clip.stopAt = clip.stopAt or pcmPos
    finishClip("stopped")
end
publish("stopped", "stopped")
