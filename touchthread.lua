-- 后台读 GT911。主线程只取最新坐标，I2C 等待不再拖住这一帧。

require("love.timer")
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

local out = love.thread.getChannel("rgds-touch")
local ctl = love.thread.getChannel("rgds-touch-ctl")

local fd = ffi.C.open("/dev/i2c-5", 2, 0)
if fd < 0 then
    out:push({kind = "err", text = "cannot open /dev/i2c-5"})
    return
end

local wbuf = ffi.new("uint8_t[3]")
local rbuf = ffi.new("uint8_t[8]")
local msgs = ffi.new("struct rgds_i2c_msg[2]")
local rd = ffi.new("struct rgds_i2c_rdwr")

local function xfer(reg, nread, extra)
    wbuf[0] = bit.rshift(reg, 8)
    wbuf[1] = bit.band(reg, 0xff)
    local wlen = 2
    if extra ~= nil then
        wbuf[2] = extra
        wlen = 3
    end
    msgs[0].addr = ADDR
    msgs[0].flags = 0
    msgs[0].len = wlen
    msgs[0].buf = wbuf
    local nmsgs = 1
    if nread > 0 then
        msgs[1].addr = ADDR
        msgs[1].flags = I2C_M_RD
        msgs[1].len = nread
        msgs[1].buf = rbuf
        nmsgs = 2
    end
    rd.msgs = msgs
    rd.nmsgs = nmsgs
    if ffi.C.ioctl(fd, I2C_RDWR, rd) < 0 then return false end
    return true
end

local xmax, ymax = 640, 480
if xfer(0x8047, 6) then
    local x = rbuf[1] + rbuf[2] * 256
    local y = rbuf[3] + rbuf[4] * 256
    if x > 0 and y > 0 then xmax, ymax = x, y end
end
out:push({kind = "ready", xmax = xmax, ymax = ymax})

local down = false
local lastX, lastY = 0, 0
while ctl:pop() ~= "stop" do
    if not xfer(0x814E, 8) then
        love.timer.sleep(0.02)
    else
        local status = rbuf[0]
        if bit.band(status, 0x80) ~= 0 then
            local count = bit.band(status, 0x0f)
            local x = rbuf[2] + rbuf[3] * 256
            local y = rbuf[4] + rbuf[5] * 256
            xfer(0x814E, 0, 0)
            if count >= 1 then
                x = math.max(0, math.min(639, x * 640 / xmax))
                y = math.max(0, math.min(479, y * 480 / ymax))
                if not down or x ~= lastX or y ~= lastY then
                    lastX, lastY = x, y
                    down = true
                    out:push({kind = "pt", down = true, x = x, y = y})
                end
            elseif down then
                down = false
                out:push({kind = "pt", down = false, x = lastX, y = lastY})
            end
        elseif down then
            down = false
            out:push({kind = "pt", down = false, x = lastX, y = lastY})
        end
        love.timer.sleep(down and 0.002 or 0.008)
    end
end

ffi.C.close(fd)
