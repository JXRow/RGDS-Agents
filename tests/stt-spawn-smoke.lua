-- LuaJIT FFI smoke test for the same spawn path sttthread.lua uses. Not part of the game.
local ffi = require("ffi")
ffi.cdef[[
typedef struct { int allocated; int used; void *actions; int pad[32]; } rgds_spawn_actions;
int pipe(int *pipefd);
int close(int fd);
long read(int fd, void *buf, unsigned long count);
int posix_spawn_file_actions_init(rgds_spawn_actions *fa);
int posix_spawn_file_actions_destroy(rgds_spawn_actions *fa);
int posix_spawn_file_actions_adddup2(rgds_spawn_actions *fa, int fd, int newfd);
int posix_spawn_file_actions_addclose(rgds_spawn_actions *fa, int fd);
int posix_spawn(int *pid, const char *path, rgds_spawn_actions *fa, void *attrp, char **argv, char **envp);
char *strerror(int errnum);
int waitpid(int pid, int *status, int options);
]]

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

local pin, pout = ffi.new("int[2]"), ffi.new("int[2]")
assert(ffi.C.pipe(pin) == 0 and ffi.C.pipe(pout) == 0)
local acts = ffi.new("rgds_spawn_actions")
assert(ffi.C.posix_spawn_file_actions_init(acts) == 0)
assert(ffi.C.posix_spawn_file_actions_adddup2(acts, pout[0], 0) == 0)
assert(ffi.C.posix_spawn_file_actions_adddup2(acts, pin[1], 1) == 0)
for _, fd in ipairs({pin[0], pin[1], pout[0], pout[1]}) do
    assert(ffi.C.posix_spawn_file_actions_addclose(acts, fd) == 0)
end
local argv = {"/usr/bin/taskset", "-c", "2,3", "/usr/bin/nice", "-n", "19", "/bin/echo", "hello-from-taskset"}
local arr, keep = cargv(argv)
local pidp = ffi.new("int[1]")
local rc = ffi.C.posix_spawn(pidp, argv[1], acts, nil, arr, nil)
keep = nil
ffi.C.posix_spawn_file_actions_destroy(acts)
ffi.C.close(pout[0]); ffi.C.close(pin[1]); ffi.C.close(pout[1])
if rc ~= 0 then
    local err = ffi.C.strerror(rc)
    io.write("SPAWN FAIL ", rc, " ", err ~= nil and ffi.string(err) or "", "\n")
    os.exit(1)
end
local buf = ffi.new("char[64]")
local n = tonumber(ffi.C.read(pin[0], buf, 64))
io.write("READ ", n, " [", n > 0 and ffi.string(buf, n) or "", "]\n")
local st = ffi.new("int[1]")
ffi.C.waitpid(pidp[0], st, 0)
ffi.C.close(pin[0])
if n < 18 or not ffi.string(buf, n):find("hello-from-taskset", 1, true) then os.exit(1) end
io.write("SMOKE OK\n")
