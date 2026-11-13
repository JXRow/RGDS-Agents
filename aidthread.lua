-- 常驻对话线程。拉起 rgds-aid（本机 TCP，NDJSON），把主线程送来的请求写进去，
-- 把流式回复推回 rgds-aid-ev。助手、密钥或网络出问题只报错，不碰游戏本身。

local cfg = ...
if type(cfg) ~= "table" then return end

require("love.thread")
local ffi = require("ffi")
local bit = require("bit")

ffi.cdef[[
typedef struct {
  int allocated;
  int used;
  void *actions;
  int pad[32];
} rgds_spawn_actions;
int open(const char *path, int flags, ...);
int close(int fd);
int kill(int pid, int sig);
int waitpid(int pid, int *status, int options);
int posix_spawn_file_actions_init(rgds_spawn_actions *fa);
int posix_spawn_file_actions_destroy(rgds_spawn_actions *fa);
int posix_spawn_file_actions_adddup2(rgds_spawn_actions *fa, int fd, int newfd);
int posix_spawn_file_actions_addclose(rgds_spawn_actions *fa, int fd);
int posix_spawn(int *pid, const char *path, rgds_spawn_actions *fa, void *attrp,
                char **argv, char **envp);
char *strerror(int errnum);
struct timespec { long tv_sec; long tv_nsec; };
int nanosleep(const struct timespec *req, struct timespec *rem);
]]

local O_WRONLY, O_CREAT, O_TRUNC, O_CLOEXEC = 1, 64, 512, 0x80000
local SIGTERM, WNOHANG = 15, 1
local PID_FILE = "/tmp/rgds-aid.pid"
local PORT = tonumber(cfg.port) or 7788

local jobChannel = love.thread.getChannel("rgds-aid-job")
local evChannel = love.thread.getChannel("rgds-aid-ev")
local childPid = -1

local function pushEv(t)
    pcall(function() evChannel:push(t) end)
end

local function sleepMs(ms)
    local req = ffi.new("struct timespec")
    req.tv_sec = math.floor(ms / 1000)
    req.tv_nsec = (ms % 1000) * 1000000
    ffi.C.nanosleep(req, nil)
end

local function cargv(list)
    local arr = ffi.new("char*[?]", #list + 1)
    local keep = {}
    for i, s in ipairs(list) do
        local buf = ffi.new("char[?]", #s + 1)
        ffi.copy(buf, s)
        keep[i] = buf
        arr[i - 1] = buf
    end
    arr[#list] = nil
    return arr, keep
end

local function closeFd(fd)
    if fd and fd >= 0 then ffi.C.close(fd) end
end

local function procText(pid, name)
    local f = io.open("/proc/" .. pid .. "/" .. name, "rb")
    if not f then return "" end
    local s = f:read("*a") or ""
    f:close()
    return (s:gsub("%z", " "))
end

local function isHelper(pid)
    local cmd = procText(pid, "cmdline")
    return cmd:find("rgds-aid.py", 1, true) ~= nil
end

local function reapStale()
    local f = io.open(PID_FILE, "r")
    if not f then return end
    local pid = tonumber(f:read("*a"))
    f:close()
    if not pid or pid <= 0 or not isHelper(pid) then return end
    ffi.C.kill(pid, SIGTERM)
    for _ = 1, 40 do
        if procText(pid, "cmdline") == "" then break end
        sleepMs(50)
    end
end

local function writePid(pid)
    local f = io.open(PID_FILE, "w")
    if f then
        f:write(tostring(pid))
        f:close()
    end
end

local function shutdownChild()
    if childPid > 0 then
        local st = ffi.new("int[1]")
        local r = tonumber(ffi.C.waitpid(childPid, st, WNOHANG))
        if r == 0 then
            ffi.C.kill(childPid, SIGTERM)
            for _ = 1, 20 do
                if tonumber(ffi.C.waitpid(childPid, st, WNOHANG)) ~= 0 then break end
                sleepMs(50)
            end
        end
        childPid = -1
    end
    os.remove(PID_FILE)
end

local function spawnHelper()
    local acts = ffi.new("rgds_spawn_actions")
    if ffi.C.posix_spawn_file_actions_init(acts) ~= 0 then
        return nil, "spawn actions failed"
    end
    local logfd = ffi.C.open(cfg.log or "/tmp/rgds-aid.log",
        bit.bor(O_WRONLY, O_CREAT, O_TRUNC, O_CLOEXEC), 420)
    local devnull = ffi.C.open("/dev/null", 0)
    if logfd >= 0 then
        ffi.C.posix_spawn_file_actions_adddup2(acts, logfd, 1)
        ffi.C.posix_spawn_file_actions_adddup2(acts, logfd, 2)
    end
    if devnull >= 0 then
        ffi.C.posix_spawn_file_actions_adddup2(acts, devnull, 0)
    end
    if logfd >= 0 then ffi.C.posix_spawn_file_actions_addclose(acts, logfd) end
    if devnull >= 0 then ffi.C.posix_spawn_file_actions_addclose(acts, devnull) end

    local argv = {cfg.python or "/usr/bin/python3", "-u", cfg.script}
    local arr, keep = cargv(argv)
    local pidp = ffi.new("int[1]")
    local rc = ffi.C.posix_spawn(pidp, argv[1], acts, nil, arr, nil)
    keep = nil
    ffi.C.posix_spawn_file_actions_destroy(acts)
    closeFd(logfd)
    closeFd(devnull)
    if rc ~= 0 then
        local err = ffi.C.strerror(rc)
        return nil, "could not start helper (" .. (err ~= nil and ffi.string(err) or tostring(rc)) .. ")"
    end
    childPid = tonumber(pidp[0])
    writePid(childPid)
    return childPid
end

-- 只覆盖协议里用到的 JSON。字符串按 UTF-8 原样进出。
local function jsonEscape(s)
    return (s:gsub('[%z\1-\31\\"]', function(c)
        if c == '"' then return '\\"' end
        if c == "\\" then return "\\\\" end
        if c == "\n" then return "\\n" end
        if c == "\r" then return "\\r" end
        if c == "\t" then return "\\t" end
        return string.format("\\u%04x", c:byte())
    end))
end

local function jsonEncode(v)
    local t = type(v)
    if t == "string" then return '"' .. jsonEscape(v) .. '"' end
    if t == "number" then return string.format("%.14g", v) end
    if t == "boolean" then return v and "true" or "false" end
    if t == "nil" then return "null" end
    if t ~= "table" then return "null" end
    local parts = {}
    for k, val in pairs(v) do
        parts[#parts + 1] = '"' .. jsonEscape(tostring(k)) .. '":' .. jsonEncode(val)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function jsonDecode(s)
    local i, n = 1, #s
    local function peek() return s:byte(i) end
    local function skip()
        while i <= n do
            local b = peek()
            if b ~= 32 and b ~= 9 and b ~= 10 and b ~= 13 then break end
            i = i + 1
        end
    end
    local parseValue
    local function parseString()
        i = i + 1
        local out = {}
        while i <= n do
            local b = peek()
            if b == 34 then i = i + 1 return table.concat(out) end
            if b == 92 then
                local e = s:byte(i + 1)
                if e == 117 then
                    local cp = tonumber(s:sub(i + 2, i + 5), 16)
                    if not cp then return nil end
                    if cp < 0x80 then
                        out[#out + 1] = string.char(cp)
                    elseif cp < 0x800 then
                        out[#out + 1] = string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
                    else
                        out[#out + 1] = string.char(
                            0xE0 + math.floor(cp / 4096),
                            0x80 + math.floor(cp / 64) % 64,
                            0x80 + cp % 64)
                    end
                    i = i + 6
                else
                    local ch = s:sub(i + 1, i + 1)
                    if e == 110 then ch = "\n"
                    elseif e == 114 then ch = "\r"
                    elseif e == 116 then ch = "\t" end
                    out[#out + 1] = ch
                    i = i + 2
                end
            else
                out[#out + 1] = s:sub(i, i)
                i = i + 1
            end
        end
        return nil
    end
    local function parseNumber()
        local start = i
        if peek() == 45 then i = i + 1 end
        while i <= n and peek() >= 48 and peek() <= 57 do i = i + 1 end
        if i <= n and peek() == 46 then
            i = i + 1
            while i <= n and peek() >= 48 and peek() <= 57 do i = i + 1 end
        end
        local exp = i <= n and peek()
        if exp == 101 or exp == 69 then
            i = i + 1
            local sign = i <= n and peek()
            if sign == 43 or sign == 45 then i = i + 1 end
            while i <= n and peek() >= 48 and peek() <= 57 do i = i + 1 end
        end
        return tonumber(s:sub(start, i - 1))
    end
    function parseValue()
        skip()
        local b = peek()
        if b == nil then return nil end
        if b == 34 then return parseString() end
        if b == 123 then
            i = i + 1
            local obj = {}
            skip()
            if peek() == 125 then i = i + 1 return obj end
            while true do
                skip()
                if peek() ~= 34 then return nil end
                local k = parseString()
                if k == nil then return nil end
                skip()
                if peek() ~= 58 then return nil end
                i = i + 1
                local val = parseValue()
                if val ~= nil or s:sub(i - 4, i - 1) == "null" then obj[k] = val end
                skip()
                local c = peek()
                if c == 125 then i = i + 1 return obj end
                if c ~= 44 then return nil end
                i = i + 1
            end
        end
        if b == 91 then
            i = i + 1
            local arr = {}
            skip()
            if peek() == 93 then i = i + 1 return arr end
            while true do
                arr[#arr + 1] = parseValue()
                skip()
                local c = peek()
                if c == 93 then i = i + 1 return arr end
                if c ~= 44 then return nil end
                i = i + 1
            end
        end
        if s:sub(i, i + 3) == "true" then i = i + 4 return true end
        if s:sub(i, i + 4) == "false" then i = i + 5 return false end
        if s:sub(i, i + 3) == "null" then i = i + 4 return nil end
        if b == 45 or (b >= 48 and b <= 57) then return parseNumber() end
        return nil
    end
    return parseValue()
end

local function sendAll(tcp, payload)
    local i = 1
    while i <= #payload do
        local last, err, part = tcp:send(payload, i)
        if last then
            i = last + 1
        elseif part and part >= i then
            i = part + 1
        else
            return false, err
        end
    end
    return true
end

local function failQueued(kind, detail)
    local job = jobChannel:pop()
    while job do
        if job.op == "chat" and job.id then
            pushEv({ev = "error", id = job.id, kind = kind, msg = detail})
        end
        if job.op == "stop" then return true end
        job = jobChannel:pop()
    end
    return false
end

reapStale()
local pid, err = spawnHelper()
if not pid then
    pushEv({ev = "error", kind = "helper", msg = err or "could not start helper"})
    failQueued("helper", err or "could not start helper")
    return
end

local socketOk, socket = pcall(require, "socket")
if not socketOk then
    pushEv({ev = "error", kind = "helper", msg = "no socket"})
    failQueued("helper", "no socket")
    shutdownChild()
    return
end

local tcp
for _ = 1, 50 do
    local job = jobChannel:peek()
    if job and job.op == "stop" then
        jobChannel:pop()
        shutdownChild()
        return
    end
    local client = socket.tcp()
    client:settimeout(0.2)
    local ok = client:connect("127.0.0.1", PORT)
    if ok then
        client:settimeout(0.05)
        tcp = client
        break
    end
    client:close()
    socket.sleep(0.1)
end

if not tcp then
    pushEv({ev = "error", kind = "helper", msg = "helper did not listen"})
    failQueued("helper", "helper did not listen")
    shutdownChild()
    return
end

pushEv({ev = "ready"})

local buf = ""
local running = true
while running do
    if childPid > 0 and procText(childPid, "cmdline") == "" then
        pushEv({ev = "error", kind = "helper", msg = "helper stopped"})
        break
    end
    local chunk, recErr, partial = tcp:receive(2048)
    local data = chunk or partial
    if data and #data > 0 then
        buf = buf .. data
        while true do
            local nl = buf:find("\n", 1, true)
            if not nl then break end
            local line = buf:sub(1, nl - 1)
            buf = buf:sub(nl + 1)
            if line ~= "" then
                local ev = jsonDecode(line)
                if type(ev) == "table" then pushEv(ev) end
            end
        end
    elseif recErr == "closed" then
        pushEv({ev = "error", kind = "helper", msg = "helper stopped"})
        break
    end

    local job = jobChannel:pop()
    while job do
        if job.op == "stop" then
            running = false
            break
        end
        local okSend = sendAll(tcp, jsonEncode(job) .. "\n")
        if not okSend then
            if job.op == "chat" and job.id then
                pushEv({ev = "error", id = job.id, kind = "helper", msg = "helper stopped"})
            end
            running = false
            break
        end
        job = jobChannel:pop()
    end
    if running and (not data or #data == 0) then
        socket.sleep(0.02)
    end
end

pcall(function() tcp:close() end)
shutdownChild()
