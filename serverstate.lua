-- Map the OpenCode sources already on the device onto one server row.
-- Pure Lua 5.1: no love, no socket, no io.popen. The caller reads files and
-- the status script, then passes them in.
--
-- row = M.map({
--   configPath = M.paths.configFile,   -- or configText, or model
--   setupPath = M.paths.setupFile,     -- or setupText, or setup = {url, token}
--   statusLine = line,                  -- one line from the status script
--   statusExit = code,                  -- shell exit code, from parseProbe
--   adapter = event,                    -- latest {ev="status"} or {ev="error"}
--   lastStatus = statusEvent,           -- kept when adapter is a turn error
--   phase = aid.phase,                  -- "loading" is Starting
--   startPending = true,                -- start/restart has not returned
--   startExit = code,                   -- shell exit code of that command
--   startLine = line,                   -- its last line
--   unhealthySeconds = n,               -- how long health has stayed unhealthy
-- })
--
-- Wiring, once the agent UI owns the bottom panel:
--   Probe in a love.thread with io.popen, the same way main.lua probes the
--   network. The command is M.probeCommand(script). file:close() does not
--   return the shell exit code; M.parseProbe reads the " rc=N" line.
--   Once at startup, then every M.POLL_S while row.state ~= "running".
--   Pass adapter events as they arrive. Do not wait for the next probe.
--   Button row.action:
--     start, restart: thread runs M.actionCommand(action, script).
--       Set startPending until parseProbe returns startExit and startLine.
--     wizard: start M.paths.wizard in the background. It writes the setup
--       file and deletes that file when it exits. Do not wait on it.
--   Clear unhealthySeconds unless the parsed health is "unhealthy".
--   The first unhealthy reading (nil or 0) is Starting. At
--   M.UNHEALTHY_LIMIT_S it is Failed. M.POLL_S is the plan's guess.
--   Before start or restart, the caller clears statusLine, statusExit,
--   adapter, lastStatus, and unhealthySeconds. map() treats a leftover
--   healthy reading as current, so a non-zero startExit is ignored when
--   health and net are both ok.

local M = {}

M.POLL_S = 5
M.UNHEALTHY_LIMIT_S = 15

M.paths = {
    service = "opencode/opencode-service.sh",
    wizard = "opencode/opencode-setup-web.py",
    setupFile = "/tmp/opencode-setup.json",
    configFile = "/userdata/opencode/config/opencode/opencode.json",
    logFile = "/tmp/opencode-serve.log",
}

M.word = {
    not_configured = "Not configured",
    starting = "Starting",
    running = "Running",
    failed = "Failed",
    auth = "Auth problem",
}

local FAILED_KIND = {
    offline = true,
    server = true,
    helper = true,
}

local function trim(text)
    if type(text) ~= "string" then return "" end
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function shQuote(text)
    return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

function M.probeCommand(script)
    return shQuote(script or M.paths.service) .. ' status; echo " rc=$?"'
end

function M.actionCommand(action, script, wizard)
    if action == "start" or action == "restart" then
        return shQuote(script or M.paths.service) .. " " .. action .. ' 2>&1; echo " rc=$?"'
    end
    if action == "wizard" then
        -- vfat/exfat does not keep the execute bit. Same interpreter as aid.lua.
        return "/usr/bin/python3 " .. shQuote(wizard or M.paths.wizard)
    end
    return nil
end

-- Last non-empty line, plus the shell exit code from a trailing " rc=N".
function M.parseProbe(text)
    if type(text) ~= "string" then return nil, nil end
    local exitCode = nil
    local last = nil
    for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
        local line = raw:gsub("\r$", "")
        local rc = line:match("^ rc=(%d+)%s*$")
        if rc then
            exitCode = tonumber(rc)
        elseif line ~= "" then
            last = line
        end
    end
    return last, exitCode
end

-- "running (pid: N, health: ok)" and the two exit-1 lines from status.
function M.parseStatus(line)
    if type(line) ~= "string" then return nil end
    local text = trim(line)
    local state, pid, health = text:match("^(running) %(pid: ([^,]+), health: (%a+)%)$")
    if not state then
        state, pid, health = text:match("^(stopped) %(pid: ([^,]+), health: (%a+)%)$")
    end
    if not state then return nil end
    if health ~= "ok" and health ~= "unhealthy" and health ~= "down" then return nil end
    if pid == "" then return nil end
    return {state = state, pid = pid, health = health}
end

-- Same rule as aid.lua readSetup: http(s) URL and a 6-character token.
function M.parseSetup(text)
    if type(text) ~= "string" then return nil end
    local url = text:match('"url"%s*:%s*"([^"]+)"')
    local token = text:match('"token"%s*:%s*"([^"]+)"')
    if type(url) ~= "string" or not url:match("^https?://") then return nil end
    if type(token) ~= "string" or not token:match("^%w%w%w%w%w%w$") then return nil end
    return {url = url, token = token}
end

local function scanJsonString(text, pos)
    if text:sub(pos, pos) ~= '"' then return nil, pos end
    local out = {}
    local i = pos + 1
    local n = #text
    while i <= n do
        local c = text:sub(i, i)
        if c == '"' then
            return table.concat(out), i + 1
        elseif c == "\\" then
            i = i + 1
            if i > n then return nil, i end
            local esc = text:sub(i, i)
            if esc == '"' or esc == "\\" or esc == "/" then
                out[#out + 1] = esc
            elseif esc == "n" then out[#out + 1] = "\n"
            elseif esc == "r" then out[#out + 1] = "\r"
            elseif esc == "t" then out[#out + 1] = "\t"
            elseif esc == "b" then out[#out + 1] = "\b"
            elseif esc == "f" then out[#out + 1] = "\f"
            else out[#out + 1] = esc
            end
        else
            out[#out + 1] = c
        end
        i = i + 1
    end
    return nil, i
end

local function skipSpaces(text, pos)
    local _, e = text:find("^[ \t\r\n]*", pos)
    return (e or (pos - 1)) + 1
end

-- Top-level JSON string stored under the key "model". Blank is missing.
function M.readModel(text)
    if type(text) ~= "string" then return nil end
    local i = skipSpaces(text, 1)
    local n = #text
    local targetDepth = text:sub(i, i) == "{" and 1 or 0
    local depth = 0
    while i <= n do
        local c = text:sub(i, i)
        if c == "{" or c == "[" then
            depth = depth + 1
            i = i + 1
        elseif c == "}" or c == "]" then
            depth = depth - 1
            if targetDepth == 1 and depth <= 0 then break end
            i = i + 1
        elseif c == '"' then
            local str, nextI = scanJsonString(text, i)
            if not str then return nil end
            i = skipSpaces(text, nextI)
            if depth == targetDepth and text:sub(i, i) == ":" then
                i = skipSpaces(text, i + 1)
                if str == "model" then
                    if text:sub(i, i) ~= '"' then return nil end
                    local val = scanJsonString(text, i)
                    if type(val) ~= "string" then return nil end
                    val = trim(val)
                    if val == "" then return nil end
                    return val
                end
            end
        else
            i = i + 1
        end
    end
    return nil
end

-- "opencode password missing", or "HTTP 401" / "HTTP 403" from the local
-- server, is the password file. Any other auth message is the provider key.
function M.authCause(msg)
    if msg == "opencode password missing" then return "password" end
    if type(msg) == "string" then
        if msg:match("^HTTP 401%f[%D]") or msg:match("^HTTP 403%f[%D]") then
            return "password"
        end
    end
    return "key"
end

local function readFile(path)
    local handle = io.open(path, "r")
    if not handle then return nil end
    local text = handle:read("*a")
    handle:close()
    return text or ""
end

local function configured(src)
    if src.model ~= nil then
        if type(src.model) ~= "string" then return false end
        return trim(src.model) ~= ""
    end
    if src.configText ~= nil then
        if type(src.configText) ~= "string" then return false end
        return M.readModel(src.configText) ~= nil
    end
    if type(src.configPath) == "string" and src.configPath ~= "" then
        local text = readFile(src.configPath)
        if text == nil then return false end
        return M.readModel(text) ~= nil
    end
    return nil
end

local function setupFrom(src)
    if type(src.setup) == "table" then
        local url = src.setup.url
        local token = src.setup.token
        if type(url) ~= "string" or not url:match("^https?://") then return nil end
        if type(token) ~= "string" or not token:match("^%w%w%w%w%w%w$") then return nil end
        return {url = url, token = token}
    end
    if type(src.setupText) == "string" then
        return M.parseSetup(src.setupText)
    end
    if type(src.setupPath) == "string" and src.setupPath ~= "" then
        local text = readFile(src.setupPath)
        if text == nil then return nil end
        return M.parseSetup(text)
    end
    return nil
end

local function asEvent(ev, kind)
    if type(ev) ~= "table" or ev.ev ~= kind then return nil end
    return ev
end

local function result(state, detail, action, extra)
    extra = extra or {}
    return {
        state = state,
        word = M.word[state],
        detail = detail,
        action = action,
        holdChat = state == "starting",
        version = extra.version,
        setup = extra.setup,
        log = state == "failed" and M.paths.logFile or nil,
        authCause = extra.authCause,
    }
end

local function withSetup(setup)
    if setup then return {setup = setup} end
    return nil
end

function M.map(src)
    if type(src) ~= "table" then src = {} end
    local setup = setupFrom(src)
    local known = configured(src)

    if known == false then
        if setup then
            return result("not_configured", setup.token .. "  " .. setup.url, nil, withSetup(setup))
        end
        return result("not_configured", "No model configured", "wizard", nil)
    end

    local base = withSetup(setup)

    if src.startPending == true then
        return result("starting", "Starting the server", nil, base)
    end

    local adapter = type(src.adapter) == "table" and src.adapter or nil
    local errorEv = asEvent(adapter, "error")
    local statusEv = asEvent(adapter, "status")
    if not statusEv then
        statusEv = asEvent(src.lastStatus, "status")
    end

    if errorEv and errorEv.kind == "auth" then
        local cause = M.authCause(errorEv.msg)
        local detail = errorEv.msg
        if type(detail) ~= "string" or detail == "" then detail = "auth" end
        local action
        if cause == "password" then
            action = "restart"
        elseif not setup then
            action = "wizard"
        end
        return result("auth", detail, action, {
            setup = setup,
            authCause = cause,
        })
    end

    local status = M.parseStatus(src.statusLine)
    local statusExit = src.statusExit
    if type(statusExit) == "string" then statusExit = tonumber(statusExit) end
    local healthOk = status and status.health == "ok" and statusExit == 0
    local netOk = statusEv and statusEv.net == "ok"

    local startExit = src.startExit
    if type(startExit) == "string" then startExit = tonumber(startExit) end
    if type(startExit) == "number" and startExit ~= 0 and not (healthOk and netOk) then
        local detail = src.startLine
        if type(detail) ~= "string" or trim(detail) == "" then detail = "start failed" end
        return result("failed", detail, "start", base)
    end

    if status and status.health == "unhealthy" then
        local secs = src.unhealthySeconds
        if type(secs) == "string" then secs = tonumber(secs) end
        if type(secs) ~= "number" or secs < 0 then secs = 0 end
        if secs >= M.UNHEALTHY_LIMIT_S then
            return result("failed", "Not healthy within 15s", "start", base)
        end
        return result("starting", "Server not healthy yet", nil, base)
    end

    if status and (status.state == "stopped" or status.health == "down") then
        local detail = trim(src.statusLine)
        if detail == "" then detail = "stopped" end
        return result("failed", detail, "start", base)
    end

    if errorEv and FAILED_KIND[errorEv.kind] then
        local detail = errorEv.msg
        if type(detail) ~= "string" or detail == "" then detail = errorEv.kind end
        return result("failed", detail, "start", base)
    end

    if statusEv and statusEv.net == "offline" then
        return result("failed", "offline", "start", base)
    end

    if healthOk and netOk then
        local version = statusEv.version
        if type(version) ~= "string" then version = nil end
        version = version and trim(version) or nil
        if version == "" then version = nil end
        return result("running", version or "ok", "restart", {
            setup = setup,
            version = version,
        })
    end

    if src.phase == "loading" then
        return result("starting", "Adapter loading", nil, base)
    end

    if healthOk then
        return result("starting", "Waiting for the adapter", nil, base)
    end

    -- A probe that cannot run (126/127), or that exits non-zero with no
    -- status line, will never become healthy. Hold chat only while a real
    -- status line is merely unparsed (the "nope" + exit 1 case).
    if not status and type(statusExit) == "number" and statusExit ~= 0 then
        local line = src.statusLine
        local missing = type(line) ~= "string" or trim(line) == ""
        if statusExit == 126 or statusExit == 127 or missing then
            local detail = line
            if missing then detail = "status probe failed" end
            return result("failed", detail, "start", base)
        end
    end

    return result("starting", "Checking the server", nil, base)
end

return M
