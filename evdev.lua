-- 直接读触摸屏 evdev（本机 /dev/input/event1，Goodix gt9xx）。
-- Weston 不把这块屏的触摸派发给 SDL 窗口，所以 love.touch* 收不到真实点按。
-- 触摸面板在下屏，坐标按 absinfo 归一到 640x480，和主屏绘制同一套。
-- 每帧 pump：BTN_TOUCH 按下/抬起、ABS_MT Type-B、SYN_REPORT 时回调
-- onPointer(phase, x, y)。phase 为 true（按下）、"move"、false（抬起）。

local ffi = require("ffi")
local bit = require("bit")

ffi.cdef[[
typedef struct {
    int64_t sec, usec;
    uint16_t type, code;
    int32_t value;
} rgds_input_event;
typedef struct {
    int32_t value, minimum, maximum, fuzz, flat, resolution;
} rgds_input_absinfo;
int open(const char *path, int flags, int mode);
int close(int fd);
int ioctl(int fd, unsigned long request, void *arg);
long read(int fd, void *buf, unsigned long count);
]]

local O_RDONLY, O_NONBLOCK, O_CLOEXEC = 0, 0x800, 0x80000

local EV_SYN, EV_KEY, EV_ABS = 0x00, 0x01, 0x03
local ABS_X, ABS_Y = 0x00, 0x01
local ABS_MT_SLOT, ABS_MT_TRACKING_ID = 0x2f, 0x39
local ABS_MT_POSITION_X, ABS_MT_POSITION_Y = 0x35, 0x36
local BTN_TOUCH = 0x14a
local SYN_REPORT = 0x00

local function eviocgabs(abs)
    return 0x80000000 + ffi.sizeof("rgds_input_absinfo") * 0x10000 + 0x45 * 0x100 + 0x40 + abs
end

local M = {swap = false, flipX = false, flipY = false, W = 640, H = 480}

local fd = -1
local btnDown, wasDown = false, false
local curSlot = 0
local slotX, slotY, slotActive = {}, {}, {}
local lastX, lastY = -1, -1
local rawDumps = 0
local limX, limY = {min = 0, max = 0}, {min = 0, max = 0}
local onPointer
local rawBuf = ffi.new("rgds_input_event[64]")

local function getAbs(abs)
    local info = ffi.new("rgds_input_absinfo")
    if ffi.C.ioctl(fd, eviocgabs(abs), info) == 0 then
        return {min = info.minimum, max = info.maximum}
    end
    return nil
end

function M.open(path, width, height, callback)
    if love.system.getOS() ~= "Linux" then return false, "evdev: not linux" end
    path = path or "/dev/input/event1"
    fd = ffi.C.open(path, bit.bor(O_RDONLY, O_NONBLOCK, O_CLOEXEC), 0)
    if fd < 0 then return false, "evdev: cannot open " .. tostring(path) end
    limX = getAbs(ABS_X) or limX
    limY = getAbs(ABS_Y) or limY
    M.swap = limY.max > limX.max
    M.W, M.H = width or M.W, height or M.H
    onPointer = callback
    print(string.format("evdev: open %s X[%d..%d] Y[%d..%d] swap=%s",
        path, limX.min, limX.max, limY.min, limY.max, tostring(M.swap)))
    io.stdout:flush()
    return true
end

local function toScreen(rawX, rawY)
    local xRange, yRange = limX, limY
    if M.swap then
        rawX, rawY = rawY, rawX
        xRange, yRange = limY, limX
    end
    local fx = (rawX - xRange.min) / (xRange.max - xRange.min + 1)
    local fy = (rawY - yRange.min) / (yRange.max - yRange.min + 1)
    if M.flipX then fx = 1 - fx end
    if M.flipY then fy = 1 - fy end
    return math.max(0, math.min(M.W - 1, fx * M.W)),
        math.max(0, math.min(M.H - 1, fy * M.H))
end

function M.pump()
    if fd < 0 or not onPointer then return end
    local n = ffi.C.read(fd, rawBuf, 64 * ffi.sizeof("rgds_input_event"))
    if n <= 0 then return end
    local count = math.floor(tonumber(n) / ffi.sizeof("rgds_input_event"))
    local posX, posY = nil, nil
    local sawPos = false
    local function slotDown()
        for s = 0, 9 do
            if slotActive[s] then return true end
        end
        return false
    end
    local function report()
        local ax, ay
        for s = 0, 9 do
            if slotActive[s] and slotX[s] then ax, ay = slotX[s], slotY[s] break end
        end
        if not ax then ax, ay = posX, posY end
        -- 这块 Goodix 不一定带 BTN_TOUCH。有坐标、按下键或活动 slot 都算手指还在屏上。
        local down = (btnDown or slotDown() or sawPos) and ax ~= nil
        if down then
            if not wasDown then
                wasDown = true
                lastX, lastY = ax, ay
                local sx, sy = toScreen(ax, ay)
                print(string.format("evdev: down raw=(%d,%d) screen=(%.0f,%.0f)", ax, ay, sx, sy))
                io.stdout:flush()
                onPointer(true, sx, sy)
            elseif ax ~= lastX or ay ~= lastY then
                lastX, lastY = ax, ay
                local sx, sy = toScreen(ax, ay)
                onPointer("move", sx, sy)
            end
        elseif wasDown then
            wasDown = false
            local sx, sy = toScreen(lastX, lastY)
            onPointer(false, sx, sy)
        end
    end
    for i = 0, count - 1 do
        local e = rawBuf[i]
        local t, c, v = tonumber(e.type), tonumber(e.code), tonumber(e.value)
        if rawDumps < 12 then
            rawDumps = rawDumps + 1
            print(string.format("evdev: raw type=%d code=%d value=%d", t, c, v))
            io.stdout:flush()
        end
        if t == EV_KEY and c == BTN_TOUCH then
            btnDown = v ~= 0
        elseif t == EV_ABS then
            if c == ABS_MT_SLOT then
                curSlot = v
            elseif c == ABS_MT_TRACKING_ID then
                slotActive[curSlot] = v >= 0
                if v < 0 then btnDown = false end
            elseif c == ABS_MT_POSITION_X or c == ABS_X then
                slotX[c == ABS_X and 0 or curSlot] = v
                posX, sawPos = v, true
            elseif c == ABS_MT_POSITION_Y or c == ABS_Y then
                slotY[c == ABS_Y and 0 or curSlot] = v
                posY, sawPos = v, true
            end
        elseif t == EV_SYN and c == SYN_REPORT then
            report()
            sawPos = false
        end
    end
end

function M.close()
    if fd >= 0 then
        ffi.C.close(fd)
        fd = -1
    end
end

return M
