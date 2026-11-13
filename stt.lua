-- 语音识别：游戏启动时拉起常驻 sv-helper，退出时关掉。
-- 识别在 sttthread.lua 里跑，主线程只提交已经录好的片段并读结果。
-- 助手或模型出问题就把 phase 设成 "error"，游戏继续跑。

local M = {
    phase = "off",      -- off | loading | ready | busy | result | error
    detail = "",
    text = nil,
    lang = nil,
    pending = 0,
    pid = nil,
    loadMs = nil,
    decodeMs = nil,
    bannerText = nil,
    bannerLang = nil,
    bannerUntil = -1,
    serial = 0,
}

local BANNER_S = 5
local thread
local jobChannel, statusChannel

local ffi_ok, ffi = pcall(require, "ffi")
if ffi_ok then pcall(ffi.cdef, "int kill(int pid, int sig);") end

local function readable(path)
    local f = io.open(path, "rb")
    if not f then return false end
    f:close()
    return true
end

local function fail(detail)
    M.phase, M.detail, M.pending = "error", detail, 0
    print("stt: " .. detail)
    io.stdout:flush()
    return false
end

function M.start()
    if thread and thread:isRunning() then return true end
    local source = love.filesystem.getSource()
    local helper = source .. "/stt/sv-helper"
    local model = source .. "/stt/model.int8.onnx"
    local tokens = source .. "/stt/tokens.txt"
    if not readable(helper) then return fail("helper missing") end
    if not readable(model) then return fail("model missing") end
    if not readable(tokens) then return fail("tokens missing") end

    jobChannel = love.thread.getChannel("rgds-stt-job")
    statusChannel = love.thread.getChannel("rgds-stt-status")
    jobChannel:clear()
    statusChannel:clear()
    M.pending = 0
    M.phase, M.detail = "loading", ""
    thread = love.thread.newThread("sttthread.lua")
    local ok, err = pcall(function()
        thread:start({
            helper = helper, model = model, tokens = tokens,
            log = "/tmp/rgds-stt.log",
        })
    end)
    if not ok then
        thread = nil
        return fail("could not start helper (" .. tostring(err) .. ")")
    end
    print("stt: helper starting")
    io.stdout:flush()
    return true, err
end

-- pcm：16 kHz 单声道 s16le，就是录音线程交出来的那一段
function M.submit(pcm)
    if type(pcm) ~= "string" or #pcm < 2 then return end
    if not thread or not thread:isRunning() then
        if not M.start() then return end
    end
    M.pending = M.pending + 1
    M.phase = "busy"
    jobChannel:push({pcm = pcm})
end

function M.update()
    if statusChannel then
        local msg = statusChannel:pop()
        while msg do
            if msg.kind == "pid" then
                M.pid = msg.pid
            elseif msg.kind == "loading" then
                if M.pending == 0 then M.phase = "loading" end
            elseif msg.kind == "ready" then
                M.loadMs = msg.loadMs
                M.pid = msg.pid or M.pid
                M.phase = M.pending > 0 and "busy" or "ready"
                print(string.format("stt: ready (load %.0f ms)", M.loadMs or -1))
                io.stdout:flush()
            elseif msg.kind == "busy" then
                M.phase = "busy"
            elseif msg.kind == "result" then
                M.pending = math.max(0, M.pending - 1)
                M.text, M.lang, M.decodeMs = msg.text or "", msg.lang or "", msg.decodeMs
                M.serial = M.serial + 1
                M.phase = M.pending > 0 and "busy" or "result"
                if M.text ~= "" then
                    M.bannerText, M.bannerLang = M.text, M.lang
                    M.bannerUntil = love.timer.getTime() + BANNER_S
                end
            elseif msg.kind == "error" then
                M.phase, M.detail, M.pending = "error", msg.detail or "helper stopped", 0
                print("stt: " .. M.detail)
                io.stdout:flush()
            end
            msg = statusChannel:pop()
        end
    end
    if thread and M.phase ~= "off" and M.phase ~= "error" and not thread:isRunning() then
        local err = thread:getError()
        M.phase, M.pending = "error", 0
        M.detail = err and tostring(err):match("^[^\n]+") or "helper stopped"
        print("stt: " .. M.detail)
        io.stdout:flush()
    end
end

function M.bannerActive()
    return M.bannerText and M.bannerText ~= "" and love.timer.getTime() < M.bannerUntil
end

function M.stop()
    local pid = M.pid
    if not pid then
        local f = io.open("/tmp/rgds-stt.pid", "r")
        if f then
            pid = tonumber(f:read("*a"))
            f:close()
        end
    end
    if pid and pid > 0 and ffi_ok then
        pcall(function() ffi.C.kill(pid, 15) end)
    end
    if jobChannel then pcall(function() jobChannel:push({cmd = "stop"}) end) end
    if thread then
        thread:wait()
        thread = nil
    end
    M.pid = nil
end

return M
