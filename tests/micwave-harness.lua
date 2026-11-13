-- Drives the real micwave.lua (main-thread side) at ~60 Hz with the real micthread.lua as a coroutine,
-- against tests/fake-love.lua: start → live → push-to-talk press/release → onClip → stop.
-- Env: APPDIR, OUT, SECONDS.
local APPDIR, OUT = os.getenv("APPDIR"), os.getenv("OUT")
local F = dofile(APPDIR .. "/tests/fake-love.lua")
F.install(APPDIR, OUT)
local SECONDS = tonumber(os.getenv("SECONDS") or "6")
local micwave = require("micwave")

assert(micwave.start())
local t0, last, phase, frames, nextReport = F.now(), F.now(), 0, 0, 0.5
local clips, maxUpdate = {}, 0
micwave.onClip = function(c) clips[#clips + 1] = c end
local states = {}
while F.now() - t0 < SECONDS do
    F.stepThreads()
    local t = F.now()
    local dt = t - last
    last = t
    local u0 = os.clock()
    micwave.update(dt)
    micwave.drawWave(24, 326, 592, 110)
    maxUpdate = math.max(maxUpdate, os.clock() - u0)
    frames = frames + 1
    states[micwave.state] = (states[micwave.state] or 0) + 1
    local e = t - t0
    if e > 2 and phase == 0 then print("-- beginClip", micwave.beginClip()); phase = 1 end
    if e > 3.5 and phase == 1 then micwave.endClip(); print("-- endClip, recording=" .. tostring(micwave.recording)); phase = 2 end
    if e >= nextReport then
        nextReport = nextReport + 0.5
        print(string.format("t=%4.1f state=%-8s rms=%6.1f hold=%6.1f gain=x%-4.1f rec=%s %.2fs bins=%s uploads=%d v[1]=%.1f v[1183]=%.1f",
            e, micwave.state, micwave.rmsDb, micwave.holdDb, micwave.gain, tostring(micwave.recording),
            micwave.recSeconds, tostring(micwave.bins), F.meshUploads,
            F.lastVerts and F.lastVerts[1] or 0, F.lastVerts and F.lastVerts[1183] or 0))
    end
    F.realSleep(1 / 60)
end
micwave.stop()
micwave.update(0)
print("states seen:", (function() local s = {} for k, v in pairs(states) do s[#s + 1] = k .. "=" .. v end return table.concat(s, " ") end)())
print(string.format("frames %d, max micwave.update+drawWave %.2f ms, clips via onClip %d, notice %q",
    frames, maxUpdate * 1000, #clips, tostring(micwave.clipNotice)))
local data, cap, written = micwave.pcmRing()
print(string.format("pcmRing: %d bytes, cap %d samples, written %d", data:getSize(), cap, written))
assert(#clips == 1 and clips[1].ok, "expected one ok clip")
assert(not micwave.recording, "recording flag should clear after the clip")
print("OK")
