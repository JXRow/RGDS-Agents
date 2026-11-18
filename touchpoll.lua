-- 主线程侧：后台线程读 GT911，这里只取最新的点。

local M = {}
local thread
local out
local ctl
local onPointer
local announced = false
local held = false

function M.open(callback)
    if love.system.getOS() ~= "Linux" then return false, "not linux" end
    onPointer = callback
    out = love.thread.getChannel("rgds-touch")
    ctl = love.thread.getChannel("rgds-touch-ctl")
    out:clear()
    ctl:clear()
    thread = love.thread.newThread("touchthread.lua")
    thread:start()
    return true
end

function M.pump()
    if not out or not onPointer then return end
    if thread and not announced and not thread:isRunning() then
        announced = true
        local err = thread:getError()
        if err then
            print("touchpoll: " .. tostring(err))
            io.stdout:flush()
        end
    end
    while true do
        local msg = out:pop()
        if not msg then break end
        if msg.kind == "ready" and not announced then
            announced = true
            print(string.format("touchpoll: gt911 %dx%d", msg.xmax, msg.ymax))
            io.stdout:flush()
        elseif msg.kind == "err" and not announced then
            announced = true
            print("touchpoll: " .. tostring(msg.text))
            io.stdout:flush()
        elseif msg.kind == "pt" then
            if msg.down then
                onPointer(held and "move" or true, msg.x, msg.y)
                held = true
            else
                onPointer(false, msg.x, msg.y)
                held = false
            end
        end
    end
end

function M.close()
    if ctl then ctl:push("stop") end
    if thread then thread:wait() end
    thread = nil
end

return M
