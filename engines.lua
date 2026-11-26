-- 引擎表。finder 和启动器只问这张表，自己不写引擎规则。
-- 按 list 的顺序调用 detect，第一个返回 true 的生效。
-- 启动脚本、finder 画面和 pid 文件不在这里。
--
-- 一条记录有六个字段：
--   id      短名
--   label   finder 行右侧的标签
--   binary  引擎的绝对路径。文件不在时，行仍有标签，但不能启动
--   detect  function(path, kind, names) -> boolean
--           kind 是 "file" 或 "directory"。目录时 names 是顶层名字。
--           不读文件内容。LÖVE 的 .love 只读 zip 中央目录，不解包。
--   start   engines/<id>/start.sh 的绝对路径。脚本本身是后面的步骤。
--   stop    { signal = "SIGTERM", kill = "SIGKILL", after = 2 }
--           signal 之后 after 秒再发 kill。两个引擎都用这个默认。
--   edits   给 agent 的说明，不是代码。

local M = {}

local function moduleDir()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then
        src = src:sub(2)
    end
    local dir = src:match("^(.*)/")
    if not dir or dir == "" then
        dir = "."
    end
    if dir:sub(1, 1) ~= "/" then
        local pwdFile = io.popen("pwd", "r")
        local pwd = pwdFile and pwdFile:read("*l")
        if pwdFile then pwdFile:close() end
        if pwd and pwd ~= "" then
            if dir == "." then
                dir = pwd
            else
                dir = pwd .. "/" .. dir
            end
        end
    end
    return dir
end

local APP_ROOT = moduleDir()

local function defaultStop()
    return { signal = "SIGTERM", kill = "SIGKILL", after = 2 }
end

local function shquote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function clean(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    if path == "/" then
        return "/"
    end
    local stripped = path:gsub("/+$", "")
    if stripped == "" then
        return "/"
    end
    return stripped
end

local function basename(path)
    return path:match("([^/]+)$") or path
end

local function join(dir, name)
    if dir == "/" then
        return "/" .. name
    end
    return dir .. "/" .. name
end

-- 文件或目录。打不开则是 nil。空文件是文件。
local function kindOf(path)
    local dir = io.open(path .. "/.", "rb")
    if dir then
        dir:close()
        return "directory"
    end
    local file = io.open(path, "rb")
    if file then
        file:close()
        return "file"
    end
    return nil
end

local function listNames(path)
    local pipe = io.popen("ls -1A " .. shquote(path), "r")
    if not pipe then
        return {}
    end
    local names = {}
    for line in pipe:lines() do
        if line ~= "" then
            names[#names + 1] = line
        end
    end
    pipe:close()
    return names
end

local function u16(s, i)
    local b1, b2 = s:byte(i, i + 1)
    if not b2 then
        return nil
    end
    return b1 + b2 * 256
end

local function u32(s, i)
    local b1, b2, b3, b4 = s:byte(i, i + 3)
    if not b4 then
        return nil
    end
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

-- 只读中央目录。本地文件头和压缩数据都不读，所以不会解包。
-- 超过 4GB 的 zip64 中央目录偏移认不出来，返回 false。
local function zipRootHas(path, want)
    local f = io.open(path, "rb")
    if not f then
        return false
    end
    local function finish(result)
        f:close()
        return result
    end

    local size = f:seek("end")
    if not size or size < 22 then
        return finish(false)
    end
    local scan = math.min(size, 65535 + 22)
    if not f:seek("end", -scan) then
        return finish(false)
    end
    local tail = f:read(scan)
    if not tail or #tail ~= scan then
        return finish(false)
    end

    local eocd
    local i = #tail - 21
    while i >= 1 do
        if tail:sub(i, i + 3) == "PK\005\006" then
            local commentLen = u16(tail, i + 20)
            if commentLen and i + 21 + commentLen == #tail then
                eocd = i
                break
            end
        end
        i = i - 1
    end
    if not eocd then
        return finish(false)
    end

    local cdSize = u32(tail, eocd + 12)
    local cdOff = u32(tail, eocd + 16)
    -- 0xffffffff：zip64。这张表不读 zip64 的中央目录。
    if not cdSize or not cdOff or cdSize == 4294967295 or cdOff == 4294967295 then
        return finish(false)
    end
    if cdOff > size or cdSize > size - cdOff then
        return finish(false)
    end
    if cdSize == 0 then
        return finish(false)
    end
    if not f:seek("set", cdOff) then
        return finish(false)
    end
    local cd = f:read(cdSize)
    if not cd or #cd ~= cdSize then
        return finish(false)
    end

    local at = 1
    while at + 45 <= #cd do
        if cd:sub(at, at + 3) ~= "PK\001\002" then
            return finish(false)
        end
        local nameLen = u16(cd, at + 28)
        local extraLen = u16(cd, at + 30)
        local commentLen = u16(cd, at + 32)
        if not nameLen or not extraLen or not commentLen then
            return finish(false)
        end
        local nextAt = at + 46 + nameLen + extraLen + commentLen
        if nextAt < at + 46 or nextAt - 1 > #cd then
            return finish(false)
        end
        if nameLen == #want and cd:sub(at + 46, at + 45 + nameLen) == want then
            return finish(true)
        end
        at = nextAt
    end
    return finish(false)
end

-- 目录：顶层有文件 main.lua。conf.lua 可有可无，单独存在不算游戏。
-- 文件：名字以 .love 结尾，且 zip 根上有 main.lua。
local function loveDetect(path, kind, names)
    if kind == "directory" then
        names = names or {}
        for n = 1, #names do
            if names[n] == "main.lua" and kindOf(join(path, names[n])) == "file" then
                return true
            end
        end
        return false
    end
    if kind ~= "file" then
        return false
    end
    local base = basename(path)
    if base:sub(-5) ~= ".love" then
        return false
    end
    return zipRootHas(path, "main.lua")
end

-- 文件：名字以 .pak 结尾，且不是 menu.pak（大小写不敏感，跟 packfile_supported 一样）。
-- 引擎菜单用 stristr，名字里出现 .pak 就算；这里按 issue 18，必须以 .pak 结尾。
-- 目录：顶层有名为 data 的目录，大小写不敏感（Linux 的 isRawData）。
local function openborDetect(path, kind, names)
    if kind == "file" then
        local base = basename(path)
        if base:lower() == "menu.pak" then
            return false
        end
        return base:sub(-4) == ".pak"
    end
    if kind ~= "directory" then
        return false
    end
    names = names or {}
    for n = 1, #names do
        if names[n]:lower() == "data" and kindOf(join(path, names[n])) == "directory" then
            return true
        end
    end
    return false
end

M.list = {
    {
        id = "love",
        label = "LÖVE",
        binary = APP_ROOT .. "/bin/love",
        detect = loveDetect,
        start = APP_ROOT .. "/engines/love/start.sh",
        stop = defaultStop(),
        edits = "Edit the Lua files and assets in the game directory. A .love is a zip, so unpack it to a directory and edit there.",
    },
    {
        id = "openbor",
        label = "OpenBOR",
        binary = APP_ROOT .. "/engines/openbor/OpenBOR-arm64",
        detect = openborDetect,
        start = APP_ROOT .. "/engines/openbor/start.sh",
        stop = defaultStop(),
        edits = "Edit the text files under data. Models, levels, and scripts are text, and the script language is the engine's own, not Lua. Work on the loose data folder. Unpack a pak with borpak first.",
    },
}

function M.match(path, kind, names)
    path = clean(path)
    if not path or (kind ~= "file" and kind ~= "directory") then
        return nil
    end
    if kind == "directory" and type(names) ~= "table" then
        names = listNames(path)
    end
    for i = 1, #M.list do
        local entry = M.list[i]
        if entry.detect(path, kind, names) then
            return entry
        end
    end
    return nil
end

function M.owner(path)
    path = clean(path)
    if not path then
        return nil
    end
    local kind = kindOf(path)
    if not kind then
        return nil
    end
    local names
    if kind == "directory" then
        names = listNames(path)
    end
    return M.match(path, kind, names)
end

function M.startable(engine)
    return type(engine) == "table"
        and type(engine.binary) == "string"
        and kindOf(engine.binary) == "file"
end

function M.installHint(engine)
    return "install " .. engine.label .. " (" .. engine.binary .. ")"
end

-- 游戏行的 kind 行。binary 不在时是安装提示，行上的标签仍是 label。
function M.kindLine(engine)
    if type(engine) ~= "table" then
        return nil
    end
    if M.startable(engine) then
        return engine.label
    end
    return M.installHint(engine)
end

return M
