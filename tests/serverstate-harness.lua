-- lua5.1 tests for serverstate.lua. No device, no port 7788, no port 4096.
--   lua5.1 tests/serverstate-harness.lua

local src = debug.getinfo(1, "S").source
if src:sub(1, 1) == "@" then src = src:sub(2) end
local here = src:match("^(.*)/") or "."
local root = here:match("^(.*)/tests$") or "."
local M = dofile(root .. "/serverstate.lua")

local failed = 0
local checks = 0

local function check(name, cond, extra)
    checks = checks + 1
    if cond then return end
    failed = failed + 1
    io.stderr:write("FAIL " .. name)
    if extra ~= nil then io.stderr:write(" (" .. tostring(extra) .. ")") end
    io.stderr:write("\n")
end

local function tmpdir()
    local name = os.tmpname()
    os.remove(name)
    assert(os.execute("mkdir " .. name) == 0, "mkdir " .. name)
    return name
end

local function writeFile(path, text)
    local handle = assert(io.open(path, "w"))
    handle:write(text)
    handle:close()
end

local function invariants(name, row)
    check(name .. " word", row.word == M.word[row.state], row.word)
    check(name .. " hold", row.holdChat == (row.state == "starting"), row.holdChat)
    if row.state == "failed" then
        check(name .. " log", row.log == M.paths.logFile, row.log)
        check(name .. " action", row.action == "start", row.action)
    else
        check(name .. " log", row.log == nil, row.log)
    end
    if row.state == "auth" then
        local want = row.authCause == "password" and "restart" or "wizard"
        check(name .. " auth action", row.action == want, row.action)
        check(name .. " cause", row.authCause == "password" or row.authCause == "key", row.authCause)
    else
        check(name .. " cause", row.authCause == nil, row.authCause)
    end
    if row.state == "running" then
        check(name .. " restart", row.action == "restart", row.action)
    end
    if row.state == "starting" then
        check(name .. " no action", row.action == nil, row.action)
    end
    if row.state == "not_configured" then
        if row.setup then
            check(name .. " wizard running", row.action == nil, row.action)
        else
            check(name .. " wizard", row.action == "wizard", row.action)
        end
    end
end

local function expect(name, input, want)
    local row = M.map(input)
    invariants(name, row)
    for key, value in pairs(want) do
        local got = row[key]
        if key == "setup" then
            if value == nil then
                check(name .. " setup", got == nil, got)
            else
                check(name .. " setup url", got and got.url == value.url, got and got.url)
                check(name .. " setup token", got and got.token == value.token, got and got.token)
            end
        else
            check(name .. " " .. key, got == value, got)
        end
    end
    return row
end

local NIL = {}
local MODEL = "deepseek/deepseek-chat"
local CONFIG = [[{
  "model": "deepseek/deepseek-chat",
  "permissions": [{"action": "*", "effect": "allow", "resource": "*"}],
  "providers": {
    "deepseek": {
      "models": {"deepseek-chat": {"name": "deepseek-chat"}},
      "package": "@ai-sdk/openai-compatible"
    }
  },
  "update": "disable"
}
]]
local SETUP = '{"ip":"192.0.2.10","port":8787,"url":"http://192.0.2.10:8787/","token":"AB3K9M"}\n'
local OK = "running (pid: 42, health: ok)"
local SICK = "running (pid: 42, health: unhealthy)"
local DOWN = "stopped (pid: none, health: down)"

local function up(extra)
    local src = {
        model = MODEL,
        statusLine = OK,
        statusExit = 0,
        adapter = {ev = "status", net = "ok", session_id = "ses_1", version = "1.2.3"},
    }
    if extra then
        for key, value in pairs(extra) do
            if value == NIL then src[key] = nil else src[key] = value end
        end
    end
    return src
end

-- Parsers.

do
    local parsed = M.parseStatus(OK)
    check("parse ok state", parsed.state == "running", parsed.state)
    check("parse ok pid", parsed.pid == "42", parsed.pid)
    check("parse ok health", parsed.health == "ok", parsed.health)
    parsed = M.parseStatus(SICK .. "\n")
    check("parse sick", parsed.health == "unhealthy" and parsed.pid == "42")
    parsed = M.parseStatus(DOWN)
    check("parse down", parsed.state == "stopped" and parsed.health == "down" and parsed.pid == "none")
    check("parse garbage", M.parseStatus("opencode started (pid 3)") == nil)
    check("parse empty", M.parseStatus("") == nil)
    check("parse nil", M.parseStatus(nil) == nil)
end

do
    local line, code = M.parseProbe(OK .. "\n rc=0\n")
    check("probe ok line", line == OK, line)
    check("probe ok code", code == 0, code)
    line, code = M.parseProbe(DOWN .. "\n rc=1\n")
    check("probe down", line == DOWN and code == 1, code)
    line, code = M.parseProbe("opencode stopped\n!! workdir not found: /missing\n rc=1\n")
    check("probe last line", line == "!! workdir not found: /missing", line)
    check("probe last code", code == 1, code)
    line, code = M.parseProbe("no marker\n")
    check("probe no rc", line == "no marker" and code == nil, code)
    line, code = M.parseProbe(nil)
    check("probe nil", line == nil and code == nil)
end

check("model nested", M.readModel(CONFIG) == MODEL, M.readModel(CONFIG))
check("model blank", M.readModel('{"model":""}') == nil)
check("model spaces", M.readModel('{"model":"  "}') == nil)
check("model null", M.readModel('{"model":null}') == nil)
check("model number", M.readModel('{"model":1}') == nil)
check("model missing", M.readModel("{}") == nil)
check("model split", M.readModel('"model":\n  "anthropic/claude-sonnet-4-5"') == "anthropic/claude-sonnet-4-5")
check("model not text", M.readModel(nil) == nil)

do
    local setup = M.parseSetup(SETUP)
    check("setup url", setup.url == "http://192.0.2.10:8787/", setup.url)
    check("setup token", setup.token == "AB3K9M", setup.token)
    check("setup spaces", M.parseSetup('{ "url" : "https://rgds.local/", "token" : "ZX7P2Q" }').token == "ZX7P2Q")
    check("setup short", M.parseSetup(SETUP:gsub("AB3K9M", "ABC")) == nil)
    check("setup long", M.parseSetup(SETUP:gsub("AB3K9M", "ABC1234")) == nil)
    check("setup bad url", M.parseSetup(SETUP:gsub("http://", "ftp://")) == nil)
    check("setup no token", M.parseSetup('{"url":"http://rgds.local/"}') == nil)
end

check("cause missing", M.authCause("opencode password missing") == "password")
check("cause 401", M.authCause("HTTP 401 denied") == "password")
check("cause 403", M.authCause("HTTP 403") == "password")
check("cause 4012", M.authCause("HTTP 4012") == "key")
check("cause key", M.authCause("no") == "key")
check("cause empty", M.authCause("") == "key")
check("cause nil", M.authCause(nil) == "key")

check("probe cmd", M.probeCommand("/tmp/a b/opencode-service.sh")
    == [['/tmp/a b/opencode-service.sh' status; echo " rc=$?"]])
check("probe quote", M.probeCommand("a'b")
    == [['a'\''b' status; echo " rc=$?"]])
check("start cmd", M.actionCommand("start", "svc.sh")
    == [['svc.sh' start 2>&1; echo " rc=$?"]])
check("restart cmd", M.actionCommand("restart")
    == [['opencode/opencode-service.sh' restart 2>&1; echo " rc=$?"]])
check("wizard cmd", M.actionCommand("wizard", nil, "wiz.py") == "'wiz.py'")
check("bad cmd", M.actionCommand("stop") == nil)

-- The module stays a pure function.
do
    local body = assert(io.open(root .. "/serverstate.lua")):read("*a")
    local code = body:gsub("%-%-[^\n]*", "")
    check("no popen", not code:find("io.popen", 1, true))
    check("no socket", not code:find("socket", 1, true))
    check("no require", not code:find("require", 1, true))
    check("no 4096", not code:find("4096", 1, true))
    check("no 7788", not code:find("7788", 1, true))
end

-- No reading yet.
expect("empty", {}, {
    state = "starting",
    detail = "Checking the server",
    action = nil,
    setup = nil,
    version = nil,
})
expect("nil src", nil, {state = "starting", detail = "Checking the server"})

-- Not configured comes from the file only, and it wins over a live server.
expect("no model", {model = ""}, {state = "not_configured", detail = "No model configured", action = "wizard"})
expect("model false", {model = false}, {state = "not_configured", action = "wizard"})
expect("config empty", {configText = "{}"}, {state = "not_configured", action = "wizard"})
expect("config blank model", {configText = '{"model":"   "}'}, {state = "not_configured"})
expect("config text", {configText = CONFIG}, {state = "starting", detail = "Checking the server"})

expect("unconfigured but up", up({model = NIL, configText = "{}"}), {
    state = "not_configured",
    action = "wizard",
    detail = "No model configured",
})
expect("unconfigured during start", {
    configText = "{}",
    startPending = true,
    statusLine = DOWN,
    statusExit = 1,
}, {state = "not_configured", action = "wizard", detail = "No model configured"})

expect("wizard token", {
    configText = "{}",
    setupText = SETUP,
}, {
    state = "not_configured",
    action = nil,
    detail = "AB3K9M  http://192.0.2.10:8787/",
    setup = {url = "http://192.0.2.10:8787/", token = "AB3K9M"},
})

expect("bad setup ignored", {
    model = "",
    setupText = '{"url":"http://x/","token":"short"}',
}, {state = "not_configured", action = "wizard", setup = nil, detail = "No model configured"})

-- Status lines, with a model so the file gate stays open.
expect("running", up(), {
    state = "running",
    detail = "1.2.3",
    version = "1.2.3",
    action = "restart",
})
expect("running no version", up({
    adapter = {ev = "status", net = "ok", session_id = "ses_1"},
}), {state = "running", detail = "ok", version = nil})
expect("running blank version", up({
    adapter = {ev = "status", net = "ok", version = "  "},
}), {state = "running", detail = "ok", version = nil})
expect("exit string", up({statusExit = "0"}), {state = "running", version = "1.2.3"})

expect("ok without adapter", up({adapter = NIL}), {
    state = "starting",
    detail = "Waiting for the adapter",
})
expect("ok exit missing", up({statusExit = NIL, adapter = NIL}), {
    state = "starting",
    detail = "Checking the server",
})
expect("ok but exit 1", up({statusExit = 1}), {
    state = "starting",
    detail = "Checking the server",
})
expect("phase loading beats wait", up({adapter = NIL, phase = "loading"}), {
    state = "starting",
    detail = "Adapter loading",
})
expect("net ok beats loading", up({phase = "loading"}), {
    state = "running",
    detail = "1.2.3",
})

expect("unhealthy fresh", {model = MODEL, statusLine = SICK, statusExit = 1}, {
    state = "starting",
    detail = "Server not healthy yet",
})
expect("unhealthy 14", {
    model = MODEL, statusLine = SICK, statusExit = 1, unhealthySeconds = 14,
}, {state = "starting", detail = "Server not healthy yet"})
expect("unhealthy 15", {
    model = MODEL, statusLine = SICK, statusExit = 1, unhealthySeconds = 15,
}, {state = "failed", detail = "Not healthy within 15s", action = "start"})
expect("unhealthy string", {
    model = MODEL, statusLine = SICK, statusExit = 1, unhealthySeconds = "15",
}, {state = "failed", detail = "Not healthy within 15s"})
expect("unhealthy with offline", {
    model = MODEL, statusLine = SICK, statusExit = 1, unhealthySeconds = 0,
    adapter = {ev = "status", net = "offline"},
}, {state = "starting", detail = "Server not healthy yet"})

expect("stopped", {model = MODEL, statusLine = DOWN, statusExit = 1}, {
    state = "failed",
    detail = DOWN,
    action = "start",
})
expect("stopped ignores exit 0", {model = MODEL, statusLine = DOWN, statusExit = 0}, {
    state = "failed",
    detail = DOWN,
})
expect("garbage line", {model = MODEL, statusLine = "nope", statusExit = 1}, {
    state = "starting",
    detail = "Checking the server",
})

-- Adapter events while the service script says healthy and the last status
-- was net ok. Turn errors stay Running. Server errors and auth do not.
local function withEvent(ev)
    return up({
        adapter = ev,
        lastStatus = {ev = "status", net = "ok", version = "1.2.3", session_id = "ses_1"},
    })
end

expect("ev net ok", withEvent({ev = "status", net = "ok", version = "9", session_id = "s"}), {
    state = "running", version = "9", detail = "9",
})
expect("ev net offline", withEvent({ev = "status", net = "offline", session_id = "s"}), {
    state = "failed", detail = "offline",
})
expect("ev auth key", withEvent({ev = "error", kind = "auth", msg = "no", id = "r1"}), {
    state = "auth", detail = "no", action = "wizard", authCause = "key",
})
expect("ev auth password", withEvent({
    ev = "error", kind = "auth", msg = "opencode password missing",
}), {
    state = "auth",
    detail = "opencode password missing",
    action = "restart",
    authCause = "password",
})
expect("ev auth http", withEvent({ev = "error", kind = "auth", msg = "HTTP 403 no"}), {
    state = "auth", action = "restart", authCause = "password", detail = "HTTP 403 no",
})
expect("ev auth empty", withEvent({ev = "error", kind = "auth"}), {
    state = "auth", detail = "auth", action = "wizard", authCause = "key",
})
expect("ev offline", withEvent({ev = "error", kind = "offline", msg = "opencode sse down"}), {
    state = "failed", detail = "opencode sse down",
})
expect("ev offline bare", withEvent({ev = "error", kind = "offline"}), {
    state = "failed", detail = "offline",
})
expect("ev server", withEvent({ev = "error", kind = "server", msg = "boom"}), {
    state = "failed", detail = "boom",
})
expect("ev helper", withEvent({ev = "error", kind = "helper", msg = "helper stopped"}), {
    state = "failed", detail = "helper stopped",
})

for _, kind in ipairs({"timeout", "rate_limit", "interrupted", "cancelled"}) do
    expect("ev " .. kind, withEvent({ev = "error", kind = kind, msg = kind}), {
        state = "running",
        detail = "1.2.3",
        version = "1.2.3",
    })
end

-- The same events with no service reading and no saved status.
local function alone(ev)
    return {model = MODEL, adapter = ev}
end

expect("alone net ok", alone({ev = "status", net = "ok", version = "1"}), {
    state = "starting", detail = "Checking the server",
})
expect("alone net offline", alone({ev = "status", net = "offline"}), {
    state = "failed", detail = "offline",
})
expect("alone auth", alone({ev = "error", kind = "auth", msg = "no"}), {
    state = "auth", authCause = "key", action = "wizard",
})
expect("alone offline", alone({ev = "error", kind = "offline", msg = "down"}), {
    state = "failed", detail = "down",
})
expect("alone server", alone({ev = "error", kind = "server", msg = "bad json"}), {
    state = "failed", detail = "bad json",
})
expect("alone helper", alone({ev = "error", kind = "helper", msg = "no socket"}), {
    state = "failed", detail = "no socket",
})
for _, kind in ipairs({"timeout", "rate_limit", "interrupted", "cancelled"}) do
    expect("alone " .. kind, alone({ev = "error", kind = kind, msg = "x"}), {
        state = "starting",
        detail = "Checking the server",
    })
end

-- A turn error does not invent Running when net ok was never seen.
expect("timeout without net", up({
    adapter = {ev = "error", kind = "timeout", msg = "slow"},
    lastStatus = nil,
}), {state = "starting", detail = "Waiting for the adapter"})

-- Auth is more specific than an unhealthy health check.
expect("auth over unhealthy", {
    model = MODEL,
    statusLine = SICK,
    statusExit = 1,
    unhealthySeconds = 20,
    adapter = {ev = "error", kind = "auth", msg = "opencode password missing"},
}, {state = "auth", authCause = "password", action = "restart"})

-- Start owns the row until it returns, then its last line is the failure.
expect("start pending", up({
    startPending = true,
    adapter = {ev = "error", kind = "auth", msg = "no"},
    statusLine = DOWN,
    statusExit = 1,
}), {state = "starting", detail = "Starting the server"})

expect("start exit 1", {
    model = MODEL,
    statusLine = DOWN,
    statusExit = 1,
    startExit = 1,
    startLine = "!! opencode binary not executable: /opt/opencode",
}, {state = "failed", detail = "!! opencode binary not executable: /opt/opencode"})

expect("start exit 2", {
    model = MODEL,
    startExit = 2,
    startLine = "Usage: opencode-service.sh {start|stop|restart|status}",
}, {state = "failed", detail = "Usage: opencode-service.sh {start|stop|restart|status}"})

expect("start exit blank", {model = MODEL, startExit = 1, startLine = "  "}, {
    state = "failed", detail = "start failed",
})

expect("start recovered", up({
    startExit = 1,
    startLine = "!! opencode did not become healthy within 15s (log: /tmp/opencode-serve.log)",
}), {state = "running", detail = "1.2.3"})

-- Phase loading does not hide a stopped server.
expect("loading and stopped", {
    model = MODEL, phase = "loading", statusLine = DOWN, statusExit = 1,
}, {state = "failed", detail = DOWN})

expect("loading alone", {model = MODEL, phase = "loading"}, {
    state = "starting", detail = "Adapter loading",
})

-- Setup token stays on the row while the server is running, for the chat pin.
expect("running with setup", up({setupText = SETUP}), {
    state = "running",
    action = "restart",
    detail = "1.2.3",
    setup = {url = "http://192.0.2.10:8787/", token = "AB3K9M"},
})

expect("setup table", up({
    setup = {url = "http://rgds.local/", token = "ZX7P2Q", ip = "ignored"},
}), {
    state = "running",
    setup = {url = "http://rgds.local/", token = "ZX7P2Q"},
})

expect("setup table rejected", {
    model = "",
    setup = {url = "http://x/", token = "nope"},
    setupText = SETUP,
}, {state = "not_configured", action = "wizard", setup = nil})

-- Stand-in files in a temp directory, and a stand-in status script.
do
    local dir = tmpdir()
    local configPath = dir .. "/opencode.json"
    local setupPath = dir .. "/opencode-setup.json"
    writeFile(configPath, CONFIG)
    writeFile(setupPath, SETUP)
    expect("temp files", up({
        model = NIL,
        configPath = configPath,
        setupPath = setupPath,
    }), {
        state = "running",
        version = "1.2.3",
        setup = {url = "http://192.0.2.10:8787/", token = "AB3K9M"},
    })

    os.remove(configPath)
    expect("missing config", up({
        model = NIL,
        configPath = configPath,
        setupPath = setupPath,
    }), {
        state = "not_configured",
        action = nil,
        detail = "AB3K9M  http://192.0.2.10:8787/",
    })

    local script = dir .. "/status.sh"
    writeFile(script, "#!/bin/sh\necho 'running (pid: 9, health: ok)'\nexit 0\n")
    assert(os.execute("chmod +x " .. script) == 0)
    local pipe = assert(io.popen(M.probeCommand(script)))
    local output = pipe:read("*a")
    pipe:close()
    local line, code = M.parseProbe(output)
    check("live probe line", line == "running (pid: 9, health: ok)", line)
    check("live probe code", code == 0, code)
    expect("live probe map", {
        configText = CONFIG,
        statusLine = line,
        statusExit = code,
        adapter = {ev = "status", net = "ok", version = "0"},
    }, {state = "running", version = "0"})

    local failScript = dir .. "/fail.sh"
    writeFile(failScript, "#!/bin/sh\necho '!! workdir not found: /missing' >&2\nexit 1\n")
    assert(os.execute("chmod +x " .. failScript) == 0)
    pipe = assert(io.popen(M.actionCommand("start", failScript)))
    output = pipe:read("*a")
    pipe:close()
    line, code = M.parseProbe(output)
    check("live start line", line == "!! workdir not found: /missing", line)
    check("live start code", code == 1, code)
    expect("live start map", {
        model = MODEL,
        startExit = code,
        startLine = line,
        statusLine = DOWN,
        statusExit = 1,
    }, {state = "failed", detail = "!! workdir not found: /missing"})

    os.execute("rm -rf " .. dir)
end

if failed > 0 then
    io.stderr:write(string.format("%d failed, %d checks\n", failed, checks))
    os.exit(1)
end
print(string.format("ok %d", checks))
