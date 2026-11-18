-- gt9xx-0 的中断在涨，但 input 事件进不了 event1。
-- 芯片是 GT911，坐标在 I2C 0x814E。信息屏就是这块 640x480。

local ffi = require("ffi")
local bit = require("bit")

ffi.cdef[[
struct rgds_i2c_msg {
    uint16_t addr;
    uint16_t flags;
    uint16_t len;
    uint8_t *buf;
};
struct rgds_i2c_rdwr {
    struct rgds_i2c_msg *msgs;
    uint32_t nmsgs;
};
int open(const char *path, int flags, int mode);
int close(int fd);
int ioctl(int fd, unsigned long request, void *arg);
]]

local I2C_RDWR = 0x0707
local I2C_M_RD = 0x0001
local ADDR = 0x14
local O_RDWR = 2

local M = {}
local fd = -1
local onPointer
local down = false
local lastX, lastY = 0, 0
local xmax, ymax = 640, 480
local errOnce = false

local function xfer(reg, nread, extra)
    local wlen = extra and 3 or 2
    local w = ffi.new("uint8_t[3]")
    w[0] = bit.rshift(reg, 8)
    w[1] = bit.band(reg, 0xff)
    if extra then w[2] = extra end
    local r = nread > 0 and ffi.new("uint8_t[?]", nread) or nil
    local nmsgs = nread > 0 and 2 or 1
    local msgs = ffi.new("struct rgds_i2c_msg[2]")
    msgs[0].addr = ADDR
    msgs[0].flags = 0
    msgs[0].len = wlen
    msgs[0].buf = w
    if nread > 0 then
        msgs[1].addr = ADDR
        msgs[1].flags = I2C_M_RD
        msgs[1].len = nread
        msgs[1].buf = r
    end
    local rd = ffi.new("struct rgds_i2c_rdwr")
    rd.msgs = msgs
    rd.nmsgs = nmsgs
    if ffi.C.ioctl(fd, I2C_RDWR, rd) < 0 then return nil end
    return r
end

function M.open(callback)
    if love.system.getOS() ~= "Linux" then return false, "not linux" end
    fd = ffi.C.open("/dev/i2c-5", O_RDWR, 0)
    if fd < 0 then return false, "cannot open /dev/i2c-5" end
    onPointer = callback
    local cfg = xfer(0x8047, 6)
    if cfg then
        local x = cfg[1] + cfg[2] * 256
        local y = cfg[3] + cfg[4] * 256
        if x > 0 and y > 0 then xmax, ymax = x, y end
    end
    print(string.format("touchpoll: gt911 %dx%d", xmax, ymax))
    io.stdout:flush()
    return true
end

function M.pump()
    if fd < 0 or not onPointer then return end
    local buf = xfer(0x814E, 8)
    if not buf then
        if not errOnce then
            errOnce = true
            print("touchpoll: read failed")
            io.stdout:flush()
        end
        return
    end
    local status = buf[0]
    if bit.band(status, 0x80) == 0 then
        if down then
            down = false
            onPointer(false, lastX, lastY)
        end
        return
    end
    local count = bit.band(status, 0x0f)
    local x = buf[2] + buf[3] * 256
    local y = buf[4] + buf[5] * 256
    xfer(0x814E, 0, 0)
    if count < 1 then
        if down then
            down = false
            onPointer(false, lastX, lastY)
        end
        return
    end
    x = math.max(0, math.min(639, x * 640 / xmax))
    y = math.max(0, math.min(479, y * 480 / ymax))
    lastX, lastY = x, y
    if not down then
        down = true
        onPointer(true, x, y)
    else
        onPointer("move", x, y)
    end
end

function M.close()
    if fd >= 0 then
        ffi.C.close(fd)
        fd = -1
    end
end

return M
