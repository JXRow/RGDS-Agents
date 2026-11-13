-- Runs the real micthread.lua against tests/fake-love.lua and plays a scripted push-to-talk press.
-- Env: APPDIR (dir with micthread.lua), OUT (output dir), SCENARIO = ptt | maxlen | noconf | mono, SECONDS.
local ffi = require("ffi")
local APPDIR, OUT = os.getenv("APPDIR"), os.getenv("OUT")
local F = dofile(APPDIR .. "/tests/fake-love.lua")
F.install(APPDIR, OUT)
local SCENARIO = os.getenv("SCENARIO") or "ptt"
local SECONDS = tonumber(os.getenv("SECONDS") or "6")
if SCENARIO == "mono" then F.forceChannels = 1 end

local RATE = 16000
local cfg = {
    rate = RATE, pcmCap = RATE * 30, binCap = 4096, binSamples = 32, ringSamples = 8192,
    posChannel = "pos", ctlChannel = "ctl", clipChannel = "clip",
    prerollSamples = RATE / 4, tailSamples = RATE / 5,
    maxClipSamples = RATE * (SCENARIO == "maxlen" and 1 or 15), minClipSamples = RATE * 3 / 10,
    clipFile = "ptt-last.wav", needConf = true,
}
local pcmData, binData = love.data.newByteData(cfg.pcmCap * 2), love.data.newByteData(cfg.binCap * 4)
local thread = love.thread.newThread("micthread.lua")
thread:start(pcmData, binData, cfg)
local pos, ctl, clip = love.thread.getChannel("pos"), love.thread.getChannel("ctl"), love.thread.getChannel("clip")

print(string.format("scenario %s, ALSOFT_CONF=%s, default capture device %q", SCENARIO,
    tostring(os.getenv("ALSOFT_CONF")), F.defaultCaptureDevice()))
local t0, phase, nextReport = F.now(), 0, 0.5
local firstLive
local bmin = ffi.cast("int16_t *", binData.buf)
local bmax = bmin + cfg.binCap
while thread:step() do
    if thread:getError() then print("THREAD ERROR: " .. thread:getError()); os.exit(1) end
    F.realSleep(0.01)
    local t = F.now() - t0
    local p = pos:peek()
    if p and p.state == "live" and not firstLive and p.pcm > 0 then firstLive = {t = t, pcm = p.pcm, bins = p.bins} end
    if p and t >= nextReport then
        nextReport = nextReport + 0.5
        local lo, hi = 0, 0
        for i = math.max(0, p.bins - 250), p.bins - 1 do
            local j = i % cfg.binCap
            lo, hi = math.min(lo, bmin[j]), math.max(hi, bmax[j])
        end
        print(string.format("t=%4.1f %-6s %-26s pcm=%6d bins=%5d rms=%6.1f peak=%6.1f dBFS bins[%d..%d] rec=%s %.2fs",
            t, p.state, p.detail, p.pcm, p.bins, 20 * math.log10(math.max(p.rms, 1) / 32768),
            20 * math.log10(math.max(p.peak, 1) / 32768), lo, hi, tostring(p.rec), p.recSamples / RATE))
    end
    if SCENARIO ~= "noconf" then
        if t > 2 and phase == 0 then ctl:push({cmd = "clip_start", id = 1}); phase = 1; print("-- press") end
        if t > 4 and phase == 1 then ctl:push({cmd = "clip_end", id = 1}); phase = 2; print("-- release") end
    end
    local r = clip:pop()
    if r then
        print(string.format("CLIP id=%s ok=%s reason=%s samples=%s seconds=%s peak=%s path=%s", tostring(r.id),
            tostring(r.ok), tostring(r.reason), tostring(r.samples), tostring(r.seconds), tostring(r.peak), tostring(r.path)))
    end
    if t > SECONDS and phase < 3 then ctl:push("stop"); phase = 3 end
end
local wall = F.now() - t0
local p = pos:peek()
if firstLive then
    print(string.format("rates after first data: pcm %.0f samples/s, bins %.1f /s",
        (p.pcm - firstLive.pcm) / (wall - firstLive.t), (p.bins - firstLive.bins) / (wall - firstLive.t)))
end
print(string.format("final state %s (%s); thread CPU %.2f s over %.1f s wall = %.1f%% of one core",
    p.state, p.detail, F.threadCpu, wall, F.threadCpu / wall * 100))
