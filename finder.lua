-- 上屏 finder 的工作目录和列表。不画、不读手柄、不含引擎规则。
-- 画面和按键接上之后调用下面这些函数。R1 不是 finder 的键，手指不移动光标。
--
--   state = finder.open({
--     root = finder.readWorkdir(),          -- 省略 root 时用 file 或默认文件
--     appDir = love.filesystem.getSource(), -- 这个目录永远不是可启动的游戏
--     engineOf = function(path, kind, names) ... end,
--   })
--   finder.up(state)                         -- 到顶停住
--   finder.down(state)                       -- 到底停住
--   finder.back(state)                       -- 左键和 B；在根目录返回 {op="none"}
--   finder.right(state)                      -- 进入文件夹，或在 ".." 上回到上级；不启动游戏
--   act = finder.confirm(state)              -- A：op 为 "start"、"enter"、"leave" 或 "none"
--   finder.window(state)                     -- 可见的 13 行，以及窗口内的光标
--   finder.kindLine(state)
--   finder.selected(state)
--   finder.refresh(state)                    -- 重新读当前目录，光标留在同一个名字上
--
-- confirm 在可启动的游戏上返回 {op="start", path=, engine=}，目录不变。
-- 有引擎标签但不能启动的行，A 返回 {op="none"}。右键仍然进入文件夹。
-- 启动脚本由接线去跑。
-- engineOf(path, kind, names) 的 path 是逻辑绝对路径，kind 是 "dir" 或 "file"。
-- 目录的 names 是该层的名字，按字节序排，文件的 names 是 nil。
-- 返回 nil，或一张表 {id, label, startable, hint, start, ...}。
-- startable 省略时当作 true。startable 为 false 时 kind 行用 hint（没有 hint 就用 label）。
-- 接线用 engines.forFinder。engines.match 只认 kind "directory"，也不带 startable 和 hint。
-- 把 match 直接当 engineOf 时，缺 binary 的 .pak 会被当成能启动。
-- 本应用目录即使 engineOf 返回了引擎，也只当作普通文件夹。

local M = {}

M.ROWS = 13
M.DEFAULT_WORKDIR = "/mnt/mmc/Roms/APPS/RGDS-Agents"
M.WORKDIR_FILE = "/userdata/opencode/workdir"

local function shQuote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function cmdOk(cmd)
    local status = os.execute(cmd)
    return status == true or status == 0
end

local function captureLines(cmd)
    local pipe = io.popen(cmd)
    if not pipe then return nil end
    local out = {}
    for line in pipe:lines() do
        out[#out + 1] = line
    end
    pipe:close()
    return out
end

local function normalize(path)
    local absolute = path:sub(1, 1) == "/"
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == "." then
            -- skip
        elseif part == ".." then
            if #parts > 0 then
                table.remove(parts)
            elseif not absolute then
                parts[#parts + 1] = ".."
            end
        else
            parts[#parts + 1] = part
        end
    end
    if absolute then
        if #parts == 0 then return "/" end
        return "/" .. table.concat(parts, "/")
    end
    if #parts == 0 then return "." end
    return table.concat(parts, "/")
end

local function cwd()
    local lines = captureLines("pwd -L 2>/dev/null || pwd")
    if lines and lines[1] and lines[1] ~= "" then return lines[1] end
    return "."
end

local function absPath(path)
    if path:sub(1, 1) == "/" then return normalize(path) end
    return normalize(cwd() .. "/" .. path)
end

local function realpath(path)
    local lines = captureLines("readlink -f -- " .. shQuote(path) .. " 2>/dev/null")
    if not lines or not lines[1] or lines[1] == "" then return nil end
    return lines[1]
end

local function resolved(path)
    return realpath(path) or normalize(path)
end

local function inside(root, path)
    if path == root then return true end
    local prefix = root
    if prefix:sub(-1) ~= "/" then prefix = prefix .. "/" end
    return path:sub(1, #prefix) == prefix
end

local function join(root, trail)
    if #trail == 0 then return root end
    local tail = table.concat(trail, "/")
    if root == "/" then return "/" .. tail end
    return root .. "/" .. tail
end

local function classify(path)
    local quoted = shQuote(path)
    if cmdOk("test -d " .. quoted) then
        if cmdOk("test -r " .. quoted .. " -a -x " .. quoted) then
            return "dir"
        end
        return "unreadable"
    end
    if cmdOk("test -e " .. quoted) then
        return "not a directory"
    end
    return "missing"
end

-- One level, including names that point outside the work root.
-- A name that contains a newline is skipped so it cannot split into two rows.
local function listTyped(dir)
    local cmd = "nl='\n'; if cd -- " .. shQuote(dir)
        .. " 2>/dev/null && ls -1A -- . >/dev/null 2>&1; then"
        .. " for n in * .[!.]* ..?*; do"
        .. " [ -e \"$n\" ] || [ -L \"$n\" ] || continue;"
        .. " case \"$n\" in *\"$nl\"*) continue ;; esac;"
        .. " if [ -d \"$n\" ]; then printf 'd\\t%s\\n' \"$n\";"
        .. " else printf 'f\\t%s\\n' \"$n\"; fi;"
        .. " done; printf 'rc=0\\n'; else printf 'rc=1\\n'; fi"
    local lines = captureLines(cmd)
    if not lines or #lines == 0 or lines[#lines] ~= "rc=0" then return nil end
    local entries = {}
    for i = 1, #lines - 1 do
        local flag, name = lines[i]:match("^([df])\t(.*)$")
        if flag and name and name ~= "" and name ~= "." and name ~= ".." then
            local path = dir == "/" and ("/" .. name) or (dir .. "/" .. name)
            entries[#entries + 1] = {
                kind = flag == "d" and "dir" or "file",
                name = name,
                path = path,
            }
        end
    end
    return entries
end

local function childNames(dir)
    local entries = listTyped(dir)
    if not entries then return {} end
    local names = {}
    for i = 1, #entries do
        names[i] = entries[i].name
    end
    table.sort(names)
    return names
end

local function copyEngine(raw)
    if type(raw) ~= "table" then return nil end
    local engine = {}
    for key, value in pairs(raw) do
        engine[key] = value
    end
    engine.startable = engine.startable ~= false
    return engine
end

local function byName(a, b)
    return a.name < b.name
end

local function none()
    return { op = "none" }
end

local function place(state, index)
    local count = #state.rows
    if count == 0 then
        state.cursor = 0
        state.scroll = 0
        return
    end
    if index < 1 then index = 1 end
    if index > count then index = count end
    state.cursor = index
    local maxScroll = math.max(1, count - state.visible + 1)
    if state.scroll < 1 then state.scroll = 1 end
    if state.scroll > maxScroll then state.scroll = maxScroll end
    if state.cursor < state.scroll then
        state.scroll = state.cursor
    elseif state.cursor > state.scroll + state.visible - 1 then
        state.scroll = state.cursor - state.visible + 1
    end
end

local function rowFor(state, entry, real)
    local names = nil
    if entry.kind == "dir" then names = childNames(entry.path) end
    local rowReal = real or entry.path
    local engine = nil
    if rowReal ~= state.appDir and state.engineOf then
        engine = copyEngine(state.engineOf(entry.path, entry.kind, names))
    end
    local game = engine ~= nil
    local empty = entry.kind == "dir" and names ~= nil and #names == 0
    return {
        name = entry.name,
        path = entry.path,
        kind = entry.kind,
        game = game,
        startable = game and engine.startable or false,
        tag = game and engine.label or nil,
        slash = entry.kind == "dir" and not game,
        dim = entry.kind == "file" and not game,
        empty = empty,
        engine = engine,
    }
end

local function readList(state, keepName, keepScroll)
    state.rootReal = realpath(state.root) or state.root
    state.rel = table.concat(state.trail, "/")
    state.rows = {}
    state.error = nil
    local kind = classify(state.path)
    if kind ~= "dir" then
        state.error = kind
        place(state, 1)
        return
    end
    local entries = listTyped(state.path)
    if not entries then
        state.error = "unreadable"
        place(state, 1)
        return
    end
    local dirs, files = {}, {}
    for i = 1, #entries do
        local entry = entries[i]
        local real = realpath(entry.path)
        if not real or inside(state.rootReal, real) then
            entry.real = real
            if entry.kind == "dir" then
                dirs[#dirs + 1] = entry
            else
                files[#files + 1] = entry
            end
        end
    end
    table.sort(dirs, byName)
    table.sort(files, byName)
    if #state.trail > 0 then
        state.rows[1] = {
            name = "..",
            path = nil,
            kind = "up",
            game = false,
            startable = false,
            tag = nil,
            slash = false,
            dim = false,
            empty = false,
            engine = nil,
        }
    end
    for i = 1, #dirs do
        state.rows[#state.rows + 1] = rowFor(state, dirs[i], dirs[i].real)
    end
    for i = 1, #files do
        state.rows[#state.rows + 1] = rowFor(state, files[i], files[i].real)
    end
    state.scroll = keepScroll or 1
    if keepName then
        local found = nil
        for i = 1, #state.rows do
            if state.rows[i].name == keepName then
                found = i
                break
            end
        end
        if found then
            place(state, found)
        else
            place(state, state.cursor > 0 and state.cursor or 1)
        end
    else
        place(state, 1)
    end
end

local function stripWorkLine(line)
    if line:sub(-1) == "\r" then line = line:sub(1, -2) end
    return line:match("^[ \t]*(.-)[ \t]*$") or ""
end

function M.readWorkdir(file)
    local path = file
    if path == nil or path == "" then
        path = os.getenv("OPENCODE_WORKDIR_FILE")
        if path == nil or path == "" then path = M.WORKDIR_FILE end
    end
    local handle = io.open(path, "rb")
    if not handle then return M.DEFAULT_WORKDIR end
    local line = handle:read("*l")
    handle:close()
    if not line then return M.DEFAULT_WORKDIR end
    line = stripWorkLine(line)
    if line == "" then return M.DEFAULT_WORKDIR end
    return line
end

function M.open(opts)
    opts = opts or {}
    local root = opts.root
    if root == nil or root == "" then
        root = M.readWorkdir(opts.file)
    end
    local appDir = opts.appDir
    if appDir == nil or appDir == "" then appDir = M.DEFAULT_WORKDIR end
    local state = {
        root = absPath(root),
        path = absPath(root),
        rel = "",
        appDir = resolved(absPath(appDir)),
        rows = {},
        cursor = 0,
        scroll = 0,
        visible = M.ROWS,
        error = nil,
        trail = {},
        engineOf = opts.engineOf,
    }
    readList(state, nil, 1)
    return state
end

function M.refresh(state)
    local row = M.selected(state)
    readList(state, row and row.name or nil, state.scroll)
end

function M.selected(state)
    if state.cursor == 0 then return nil end
    return state.rows[state.cursor]
end

function M.window(state)
    local rows = {}
    if state.cursor == 0 then
        return { scroll = 0, cursor = 0, rows = rows }
    end
    local last = math.min(#state.rows, state.scroll + state.visible - 1)
    for i = state.scroll, last do
        rows[#rows + 1] = state.rows[i]
    end
    return {
        scroll = state.scroll,
        cursor = state.cursor - state.scroll + 1,
        rows = rows,
    }
end

function M.kindLine(state)
    if state.error then return state.error end
    local row = M.selected(state)
    if not row then return "empty" end
    if row.engine and row.engine.startable == false then
        if row.engine.hint and row.engine.hint ~= "" then return row.engine.hint end
        if row.tag and row.tag ~= "" then return row.tag end
    end
    if row.tag and row.tag ~= "" then return row.tag end
    if row.kind == "file" then return "not a game" end
    if row.kind == "dir" and row.empty then return "empty" end
    return "folder"
end

function M.up(state)
    if state.cursor <= 1 then return end
    place(state, state.cursor - 1)
end

function M.down(state)
    if state.cursor == 0 or state.cursor >= #state.rows then return end
    place(state, state.cursor + 1)
end

function M.back(state)
    if #state.trail == 0 then return none() end
    local name = state.trail[#state.trail]
    table.remove(state.trail)
    state.path = join(state.root, state.trail)
    readList(state, name, 1)
    return { op = "leave", path = state.path, name = name }
end

local function enterName(state, name)
    if type(name) ~= "string" or name == "" or name == "." or name == ".." then
        return none()
    end
    if name:find("/", 1, true) then return none() end
    local nextPath = state.path == "/" and ("/" .. name) or (state.path .. "/" .. name)
    local real = realpath(nextPath)
    if not real or not inside(state.rootReal, real) then return none() end
    if classify(nextPath) ~= "dir" then return none() end
    state.trail[#state.trail + 1] = name
    state.path = join(state.root, state.trail)
    readList(state, nil, 1)
    return { op = "enter", path = state.path, name = name }
end

function M.right(state)
    local row = M.selected(state)
    if not row then return none() end
    if row.kind == "up" then return M.back(state) end
    if row.kind == "dir" then return enterName(state, row.name) end
    return none()
end

function M.confirm(state)
    local row = M.selected(state)
    if not row then return none() end
    if row.kind == "up" then return M.back(state) end
    if row.game then
        if not row.startable then return none() end
        local real = realpath(row.path)
        if not real or not inside(state.rootReal, real) or real == state.appDir then
            return none()
        end
        local currentKind = classify(row.path)
        if row.kind == "dir" and currentKind ~= "dir" then return none() end
        if row.kind == "file" and currentKind ~= "not a directory" then return none() end
        local engine = row.engine
        if state.engineOf then
            local names = row.kind == "dir" and childNames(row.path) or nil
            engine = copyEngine(state.engineOf(row.path, row.kind, names))
            if not engine or not engine.startable then return none() end
        end
        return { op = "start", path = row.path, engine = engine }
    end
    if row.kind == "dir" then return enterName(state, row.name) end
    return none()
end

return M
