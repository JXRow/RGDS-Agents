-- 常驻语音识别线程。拉起 sv-helper（SenseVoice，2 线程，nice 19，cpu 2 和 3），
-- 模型只加载一次。主线程经 rgds-stt-job 送来 16 kHz 单声道 s16le；
-- 这里写 "PCM <n>\n" + 样本，读回一行 JSON，把文字和语言推到 rgds-stt-status。
-- 助手挂了只报错，不碰游戏本身。

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
int pipe(int *pipefd);
int open(const char *path, int flags, ...);
int close(int fd);
int dup2(int oldfd, int newfd);
long read(int fd, void *buf, unsigned long count);
long write(int fd, const void *buf, unsigned long count);
int kill(int pid, int sig);
int waitpid(int pid, int *status, int options);
int setpriority(int which, int who, int prio);
int sched_setaffinity(int pid, unsigned long cpusetsize, const unsigned long *mask);
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
local PID_FILE = "/tmp/rgds-stt.pid"

local jobChannel = love.thread.getChannel("rgds-stt-job")
local statusChannel = love.thread.getChannel("rgds-stt-status")

local childPid, readFd, writeFd = -1, -1, -1

local function log(s)
    io.write(s, "\n")
    io.flush()
end

local function pushStatus(t)
    pcall(function() statusChannel:push(t) end)
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

local function writeAll(fd, str)
    local n = #str
    if n == 0 then return true end
    local buf = ffi.new("uint8_t[?]", n)
    ffi.copy(buf, str, n)
    local off = 0
    while off < n do
        local w = tonumber(ffi.C.write(fd, buf + off, n - off))
        if w == nil or w < 0 then
            if ffi.errno() == 4 then -- EINTR
            else return false end
        elseif w == 0 then
            return false
        else
            off = off + w
        end
    end
    return true
end

local function readLine(fd)
    local buf = ffi.new("char[1]")
    local parts = {}
    local n = 0
    while n < 65536 do
        local r = tonumber(ffi.C.read(fd, buf, 1))
        if r == nil or r < 0 then
            if ffi.errno() ~= 4 then return nil end
        elseif r == 0 then
            return nil
        else
            local ch = ffi.string(buf, 1)
            if ch == "\n" then return table.concat(parts) end
            parts[#parts + 1] = ch
            n = n + 1
        end
    end
    return nil
end

local function jsonUnquote(s, i)
    if s:byte(i) ~= 34 then return nil end
    local out = {}
    i = i + 1
    while i <= #s do
        local b = s:byte(i)
        if b == 34 then return table.concat(out), i + 1 end
        if b == 92 then
            local nxt = s:byte(i + 1)
            if not nxt then return nil end
            if nxt == 110 then out[#out + 1] = "\n"
            else out[#out + 1] = string.char(nxt) end
            i = i + 2
        else
            out[#out + 1] = s:sub(i, i)
            i = i + 1
        end
    end
    return nil
end

local function jsonValue(line, key)
    local at = line:find('"' .. key .. '"', 1, true)
    if not at then return nil end
    local colon = line:find(":", at + #key + 2, true)
    if not colon then return nil end
    local q = line:find('"', colon + 1, true)
    if not q then return nil end
    return jsonUnquote(line, q)
end

local function cleanLang(s)
    s = s or ""
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    s = s:gsub("^<%|", ""):gsub("|>$", "")
    return s
end

local function commOf(pid)
    local f = io.open("/proc/" .. pid .. "/comm", "r")
    if not f then return "" end
    local s = f:read("*l") or ""
    f:close()
    return s
end

local function reapStale()
    local f = io.open(PID_FILE, "r")
    if not f then return end
    local pid = tonumber(f:read("*a"))
    f:close()
    if not pid or pid <= 0 then return end
    local comm = commOf(pid)
    if comm == "sv-helper" or comm == "taskset" or comm == "nice" then
        ffi.C.kill(pid, SIGTERM)
        for _ = 1, 40 do
            if commOf(pid) == "" then break end
            sleepMs(50)
        end
        log("stt: stopped leftover helper pid " .. pid)
    end
end

local function writePid(pid)
    local f = io.open(PID_FILE, "w")
    if f then
        f:write(tostring(pid))
        f:close()
    end
end

local function closeFd(fd)
    if fd and fd >= 0 then ffi.C.close(fd) end
end

local function shutdownChild()
    if writeFd >= 0 then
        writeAll(writeFd, "QUIT\n")
        closeFd(writeFd)
        writeFd = -1
    end
    if childPid > 0 then
        local st = ffi.new("int[1]")
        local r = tonumber(ffi.C.waitpid(childPid, st, WNOHANG))
        if r == 0 then
            ffi.C.kill(childPid, SIGTERM)
            ffi.C.waitpid(childPid, st, 0)
        end
        childPid = -1
    end
    closeFd(readFd)
    readFd = -1
    os.remove(PID_FILE)
end

local function spawnHelper()
    local pin = ffi.new("int[2]")
    local pout = ffi.new("int[2]")
    if ffi.C.pipe(pin) ~= 0 or ffi.C.pipe(pout) ~= 0 then
        return nil, "pipe failed"
    end
    local acts = ffi.new("rgds_spawn_actions")
    if ffi.C.posix_spawn_file_actions_init(acts) ~= 0 then
        closeFd(pin[0]); closeFd(pin[1]); closeFd(pout[0]); closeFd(pout[1])
        return nil, "spawn actions failed"
    end
    local function addDup(fd, dst) return ffi.C.posix_spawn_file_actions_adddup2(acts, fd, dst) end
    local function addClose(fd) return ffi.C.posix_spawn_file_actions_addclose(acts, fd) end
    addDup(pout[0], 0)
    addDup(pin[1], 1)
    local logfd = ffi.C.open(cfg.log or "/tmp/rgds-stt.log",
        bit.bor(O_WRONLY, O_CREAT, O_TRUNC, O_CLOEXEC), 420)
    if logfd >= 0 then addDup(logfd, 2) end
    for _, fd in ipairs({pin[0], pin[1], pout[0], pout[1]}) do addClose(fd) end
    if logfd >= 0 then addClose(logfd) end

    local argv = {
        "/usr/bin/taskset", "-c", "2,3",
        "/usr/bin/nice", "-n", "19",
        cfg.helper, cfg.model, cfg.tokens, "2",
    }
    local arr, keep = cargv(argv)
    local pidp = ffi.new("int[1]")
    local rc = ffi.C.posix_spawn(pidp, argv[1], acts, nil, arr, nil)
    keep = nil
    ffi.C.posix_spawn_file_actions_destroy(acts)
    closeFd(pout[0]); closeFd(pin[1]); if logfd >= 0 then closeFd(logfd) end
    if rc ~= 0 then
        closeFd(pin[0]); closeFd(pout[1])
        local err = ffi.C.strerror(rc)
        return nil, "could not start helper (" .. (err ~= nil and ffi.string(err) or tostring(rc)) .. ")"
    end
    local pid = pidp[0]
    local mask = ffi.new("unsigned long[16]")
    mask[0] = bit.bor(bit.lshift(1, 2), bit.lshift(1, 3))
    ffi.C.sched_setaffinity(pid, 128, mask)
    ffi.C.setpriority(0, pid, 19)
    return pid, pin[0], pout[1]
end

local function childAlive()
    if childPid <= 0 then return false end
    local st = ffi.new("int[1]")
    local r = tonumber(ffi.C.waitpid(childPid, st, WNOHANG))
    return r == 0
end

local function run()
    reapStale()
    pushStatus({kind = "loading"})
    local pid, rfd, wfd = spawnHelper()
    if not pid then
        pushStatus({kind = "error", detail = rfd or "could not start helper"})
        log("stt: " .. tostring(rfd))
        return
    end
    childPid, readFd, writeFd = pid, rfd, wfd
    writePid(pid)
    pushStatus({kind = "pid", pid = pid})
    log("stt: helper pid " .. pid .. " loading")

    local ready = readLine(readFd)
    if not ready or ready:sub(1, 5) ~= "READY" then
        log("stt: helper failed to start (" .. tostring(ready) .. ")")
        shutdownChild()
        pushStatus({kind = "error", detail = "helper failed to start"})
        return
    end
    local loadMs = tonumber(ready:match("load_ms=([%d%.]+)"))
    log(string.format("stt: ready in %.0f ms", loadMs or -1))
    pushStatus({kind = "ready", loadMs = loadMs, pid = pid})

    while true do
        local job = jobChannel:pop()
        if not job then
            if not childAlive() then
                log("stt: helper stopped")
                pushStatus({kind = "error", detail = "helper stopped"})
                shutdownChild()
                return
            end
            sleepMs(40)
        elseif job.cmd == "stop" then
            log("stt: stopping helper")
            shutdownChild()
            return
        elseif type(job.pcm) == "string" and #job.pcm >= 2 then
            local samples = math.floor(#job.pcm / 2)
            pushStatus({kind = "busy"})
            local header = string.format("PCM %d\n", samples)
            if not writeAll(writeFd, header) or not writeAll(writeFd, job.pcm:sub(1, samples * 2)) then
                log("stt: write to helper failed")
                pushStatus({kind = "error", detail = "helper stopped"})
                shutdownChild()
                return
            end
            local line = readLine(readFd)
            if not line then
                log("stt: helper closed the pipe")
                pushStatus({kind = "error", detail = "helper stopped"})
                shutdownChild()
                return
            end
            local lang = cleanLang(jsonValue(line, "lang"))
            local text = jsonValue(line, "text")
            local decodeMs = tonumber(line:match('"decode_ms":([%d%.]+)'))
            if not text then
                log("stt: bad helper line " .. line)
                pushStatus({kind = "error", detail = "bad helper reply"})
            else
                log(string.format("stt: result lang=%s decode=%.0f ms text=%s",
                    lang, decodeMs or -1, text))
                pushStatus({kind = "result", text = text, lang = lang, decodeMs = decodeMs})
            end
        end
    end
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    log("stt: thread error: " .. tostring(err))
    pcall(shutdownChild)
    pushStatus({kind = "error", detail = "thread error"})
end
