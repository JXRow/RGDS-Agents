-- lua5.1 tests/engines-table.lua
-- 引擎表：给定一个路径，哪个引擎认它，或者谁也不认。
-- 只用临时目录。不启动掌机，不连服务。

local function shquote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function scriptPath()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then
        src = src:sub(2)
    end
    if src:sub(1, 1) ~= "/" then
        local pwdFile = assert(io.popen("pwd", "r"))
        local pwd = assert(pwdFile:read("*l"))
        pwdFile:close()
        src = pwd .. "/" .. src
    end
    return src
end

local testDir = assert(scriptPath():match("^(.*)/"), "test path")
local appDir = assert(testDir:match("^(.*)/"), "app path")
local engines = dofile(appDir .. "/engines.lua")

local cases = 0
local function check(name, got, want)
    cases = cases + 1
    if got ~= want then
        error(name .. "\n  got:  " .. tostring(got) .. "\n  want: " .. tostring(want), 2)
    end
    print("ok  " .. name)
end

local function tag(path)
    local entry = engines.owner(path)
    return entry and entry.label or nil
end

local function writeFile(path, data)
    local f = assert(io.open(path, "wb"))
    f:write(data or "")
    f:close()
end

local function mkdir(path)
    assert(os.execute("mkdir -p " .. shquote(path)) == 0, "mkdir " .. path)
end

local function u16le(n)
    return string.char(n % 256, math.floor(n / 256) % 256)
end

local function u32le(n)
    local b1 = n % 256
    n = math.floor(n / 256)
    local b2 = n % 256
    n = math.floor(n / 256)
    local b3 = n % 256
    n = math.floor(n / 256)
    local b4 = n % 256
    return string.char(b1, b2, b3, b4)
end

-- 手写 zip。centralOnly 时不写本地文件头，用来证明检测只读中央目录。
local function writeZip(path, files, zipComment, centralOnly)
    local locals = {}
    local cds = {}
    local offset = 0
    for i = 1, #files do
        local file = files[i]
        local name = file.name
        local data = file.data or ""
        local extra = file.extra or ""
        local comment = file.comment or ""
        local method = file.method or 0
        if not centralOnly then
            local header = "PK\003\004"
                .. u16le(20) .. u16le(0) .. u16le(method)
                .. u16le(0) .. u16le(0)
                .. u32le(0)
                .. u32le(#data) .. u32le(#data)
                .. u16le(#name) .. u16le(#extra)
                .. name .. extra
            locals[#locals + 1] = header .. data
            offset = offset + #header + #data
        end
        cds[#cds + 1] = "PK\001\002"
            .. u16le(20) .. u16le(20)
            .. u16le(0) .. u16le(method)
            .. u16le(0) .. u16le(0)
            .. u32le(0)
            .. u32le(#data) .. u32le(#data)
            .. u16le(#name) .. u16le(#extra) .. u16le(#comment)
            .. u16le(0) .. u16le(0)
            .. u32le(0)
            .. u32le(centralOnly and 0 or (offset - #data - 30 - #name - #extra))
            .. name .. extra .. comment
    end
    local localAll = table.concat(locals)
    local cdAll = table.concat(cds)
    local comment = zipComment or ""
    local eocd = "PK\005\006"
        .. u16le(0) .. u16le(0)
        .. u16le(#files) .. u16le(#files)
        .. u32le(#cdAll) .. u32le(#localAll)
        .. u16le(#comment)
        .. comment
    local f = assert(io.open(path, "wb"))
    f:write(localAll, cdAll, eocd)
    f:close()
end

local function withBinary(engine, path, fn)
    local saved = engine.binary
    engine.binary = path
    local ok, err = pcall(fn)
    engine.binary = saved
    if not ok then
        error(err, 0)
    end
end

local tmpFile = assert(io.popen("mktemp -d", "r"))
local tmp = assert(tmpFile:read("*l"), "mktemp")
tmpFile:close()

local function cleanup()
    os.execute("rm -rf " .. shquote(tmp))
end

local function main()
    local fields = { "id", "label", "binary", "detect", "start", "stop", "edits" }
    check("two engines", #engines.list, 2)
    check("love is first", engines.list[1].id, "love")
    check("openbor is second", engines.list[2].id, "openbor")
    for i = 1, #engines.list do
        local entry = engines.list[i]
        for f = 1, #fields do
            local key = fields[f]
            check(entry.id .. " has " .. key, entry[key] ~= nil, true)
        end
        check(entry.id .. " detect is a function", type(entry.detect), "function")
        check(entry.id .. " edits is text", type(entry.edits), "string")
        check(entry.id .. " binary is absolute", entry.binary:sub(1, 1), "/")
        check(entry.id .. " start script path", entry.start, appDir .. "/engines/" .. entry.id .. "/start.sh")
        check(entry.id .. " stop signal", entry.stop.signal, "SIGTERM")
        check(entry.id .. " stop kill", entry.stop.kill, "SIGKILL")
        check(entry.id .. " stop after", entry.stop.after, 2)
    end
    check("love binary", engines.list[1].binary, appDir .. "/bin/love")
    check("openbor binary", engines.list[2].binary, appDir .. "/engines/openbor/OpenBOR-arm64")
    check("stop tables are not shared", engines.list[1].stop ~= engines.list[2].stop, true)
    check("labels", engines.list[1].label .. "/" .. engines.list[2].label, "LÖVE/OpenBOR")

    local loveDir = tmp .. "/love-game"
    mkdir(loveDir)
    writeFile(loveDir .. "/main.lua", "print(1)\n")
    writeFile(loveDir .. "/conf.lua", "function love.conf(t) end\n")
    check("love directory", tag(loveDir), "LÖVE")
    check("love directory keeps its slash", tag(loveDir .. "/"), "LÖVE")

    local confOnly = tmp .. "/conf-only"
    mkdir(confOnly)
    writeFile(confOnly .. "/conf.lua", "function love.conf(t) end\n")
    check("conf.lua alone is not a game", tag(confOnly), nil)

    local nested = tmp .. "/nested"
    mkdir(nested .. "/sub")
    writeFile(nested .. "/sub/main.lua", "print(1)\n")
    check("main.lua in a subdirectory is not the parent", tag(nested), nil)
    check("nested directory is love", tag(nested .. "/sub"), "LÖVE")

    local mainIsDir = tmp .. "/main-is-dir"
    mkdir(mainIsDir .. "/main.lua")
    check("directory named main.lua is not love", tag(mainIsDir), nil)

    local spaced = tmp .. "/love game"
    mkdir(spaced)
    writeFile(spaced .. "/main.lua", "print(1)\n")
    check("directory name with a space", tag(spaced), "LÖVE")

    local quoted = tmp .. "/it's a game"
    mkdir(quoted)
    writeFile(quoted .. "/main.lua", "print(1)\n")
    check("directory name with a quote", tag(quoted), "LÖVE")

    -- 调用方传入的 names 就是清单。漏了 main.lua 就不算，即使磁盘上有。
    check("stale names do not match", engines.match(loveDir, "directory", { "readme.txt" }), nil)
    check("supplied main.lua matches", engines.match(loveDir, "directory", { "main.lua" }).id, "love")

    writeZip(tmp .. "/root.love", {
        { name = "readme.txt", data = "hi", extra = "XXXX", comment = "c" },
        { name = "main.lua", data = "print(1)\n", extra = "YYYY", comment = "note" },
    }, "zip-comment")
    check("love zip with root main.lua", tag(tmp .. "/root.love"), "LÖVE")

    local before = io.open(tmp .. "/root.love", "rb")
    local beforeSize = before:seek("end")
    before:close()
    engines.owner(tmp .. "/root.love")
    local after = io.open(tmp .. "/root.love", "rb")
    local afterSize = after:seek("end")
    after:close()
    check("reading a .love does not change it", afterSize, beforeSize)
    check("reading a .love does not unpack it", tag(tmp .. "/main.lua"), nil)

    writeZip(tmp .. "/central-only.love", {
        { name = "main.lua", data = "print(1)\n" },
    }, nil, true)
    check("central directory alone is enough", tag(tmp .. "/central-only.love"), "LÖVE")

    writeZip(tmp .. "/bad-deflate.love", {
        { name = "main.lua", data = "this is not deflated", method = 8 },
    })
    check("deflated entry is not unpacked", tag(tmp .. "/bad-deflate.love"), "LÖVE")

    writeZip(tmp .. "/nested.love", {
        { name = "sub/main.lua", data = "print(1)\n" },
        { name = "conf.lua", data = "function love.conf(t) end\n" },
    })
    check("love zip without root main.lua", tag(tmp .. "/nested.love"), nil)

    writeZip(tmp .. "/conf.love", {
        { name = "conf.lua", data = "function love.conf(t) end\n" },
    })
    check("love zip with only conf.lua", tag(tmp .. "/conf.love"), nil)

    writeFile(tmp .. "/mention.love", "this mentions main.lua but is not a zip")
    check("text named .love is not a zip", tag(tmp .. "/mention.love"), nil)

    writeFile(tmp .. "/empty.love", "")
    check("empty .love", tag(tmp .. "/empty.love"), nil)

    writeZip(tmp .. "/game.zip", {
        { name = "main.lua", data = "print(1)\n" },
    })
    check("zip that is not a .love", tag(tmp .. "/game.zip"), nil)

    writeZip(tmp .. "/Game.LOVE", {
        { name = "main.lua", data = "print(1)\n" },
    })
    check("uppercase .LOVE suffix", tag(tmp .. "/Game.LOVE"), nil)

    local realLove = tmp .. "/real"
    mkdir(realLove)
    writeFile(realLove .. "/main.lua", "print(1)\n")
    assert(os.execute("cd " .. shquote(realLove) .. " && zip -q " .. shquote(tmp .. "/zipcli.love") .. " main.lua") == 0, "zip")
    check("zip tool archive with root main.lua", tag(tmp .. "/zipcli.love"), "LÖVE")

    writeFile(tmp .. "/bor.pak", "pak")
    check("pak file", tag(tmp .. "/bor.pak"), "OpenBOR")

    writeFile(tmp .. "/menu.pak", "pak")
    check("menu.pak", tag(tmp .. "/menu.pak"), nil)

    writeFile(tmp .. "/Menu.pak", "pak")
    check("Menu.pak", tag(tmp .. "/Menu.pak"), nil)

    writeFile(tmp .. "/notmenu.pak", "pak")
    check("notmenu.pak", tag(tmp .. "/notmenu.pak"), "OpenBOR")

    writeFile(tmp .. "/foo.pak.txt", "pak")
    check("name containing .pak but not ending in it", tag(tmp .. "/foo.pak.txt"), nil)

    writeFile(tmp .. "/bor.PAK", "pak")
    check("uppercase .PAK", tag(tmp .. "/bor.PAK"), nil)

    local paks = tmp .. "/Paks"
    mkdir(paks)
    writeFile(paks .. "/bor.pak", "pak")
    writeFile(paks .. "/menu.pak", "pak")
    check("Paks directory is a folder", tag(paks), nil)
    check("pak inside Paks", tag(paks .. "/bor.pak"), "OpenBOR")
    check("menu.pak inside Paks", tag(paks .. "/menu.pak"), nil)

    local loose = tmp .. "/loose"
    mkdir(loose .. "/data/chars")
    writeFile(loose .. "/data/chars/hero.txt", "idle")
    check("directory with data/", tag(loose), "OpenBOR")
    check("the data directory itself", tag(loose .. "/data"), nil)

    local dataCase = tmp .. "/data-case"
    mkdir(dataCase .. "/Data")
    check("Data directory any case", tag(dataCase), "OpenBOR")

    local dataFile = tmp .. "/data-file"
    mkdir(dataFile)
    writeFile(dataFile .. "/data", "not a directory")
    check("file named data", tag(dataFile), nil)

    local both = tmp .. "/both"
    mkdir(both .. "/data")
    writeFile(both .. "/main.lua", "print(1)\n")
    check("main.lua wins over data/", tag(both), "LÖVE")

    writeFile(tmp .. "/notes.txt", "hello")
    check("plain file", tag(tmp .. "/notes.txt"), nil)
    mkdir(tmp .. "/empty-dir")
    check("empty directory", tag(tmp .. "/empty-dir"), nil)
    check("missing path", tag(tmp .. "/no-such"), nil)
    check("empty string", tag(""), nil)

    local loveEntry = engines.owner(loveDir)
    local pakEntry = engines.owner(tmp .. "/bor.pak")
    check("matched love id", loveEntry.id, "love")
    check("matched openbor id", pakEntry.id, "openbor")

    withBinary(pakEntry, tmp .. "/missing-engine", function()
        check("missing binary is not startable", engines.startable(pakEntry), false)
        check("missing binary keeps the label", pakEntry.label, "OpenBOR")
        check("missing binary kind line", engines.kindLine(pakEntry),
            "install OpenBOR (" .. tmp .. "/missing-engine)")
    end)
    writeFile(tmp .. "/stand-in", "")
    withBinary(pakEntry, tmp .. "/stand-in", function()
        check("file binary is startable", engines.startable(pakEntry), true)
        check("present binary kind line is the label", engines.kindLine(pakEntry), "OpenBOR")
    end)
    mkdir(tmp .. "/binary-dir")
    withBinary(loveEntry, tmp .. "/binary-dir", function()
        check("directory is not a binary", engines.startable(loveEntry), false)
    end)
    check("binary path restored", pakEntry.binary, appDir .. "/engines/openbor/OpenBOR-arm64")

    -- 第三个引擎就是多一条记录。插在表头时它先匹配；插在表尾时前面的规则先赢。
    local third = {
        id = "pico",
        label = "Pico",
        binary = tmp .. "/missing-pico",
        detect = function(path, kind)
            if kind ~= "file" then
                return false
            end
            local base = path:match("([^/]+)$") or path
            return base:sub(-5) == ".pico"
        end,
        start = appDir .. "/engines/pico/start.sh",
        stop = { signal = "SIGTERM", kill = "SIGKILL", after = 2 },
        edits = "Edit the cart text.",
    }
    writeFile(tmp .. "/cart.pico", "cart")
    check("unknown suffix before the third engine", tag(tmp .. "/cart.pico"), nil)
    table.insert(engines.list, third)
    check("third engine at the end", tag(tmp .. "/cart.pico"), "Pico")
    check("third engine does not take a pak", tag(tmp .. "/bor.pak"), "OpenBOR")
    check("third engine does not take love", tag(loveDir), "LÖVE")
    check("third engine is not startable", engines.startable(engines.owner(tmp .. "/cart.pico")), false)
    table.remove(engines.list)

    local first = {
        id = "marker",
        label = "Marker",
        binary = tmp .. "/missing-marker",
        detect = function(path, kind, names)
            if kind ~= "directory" then
                return false
            end
            names = names or {}
            for n = 1, #names do
                if names[n] == "marker.txt" then
                    return true
                end
            end
            return false
        end,
        start = appDir .. "/engines/marker/start.sh",
        stop = { signal = "SIGTERM", kill = "SIGKILL", after = 2 },
        edits = "Edit marker.txt.",
    }
    writeFile(loveDir .. "/marker.txt", "x")
    table.insert(engines.list, 1, first)
    check("an earlier entry wins", tag(loveDir), "Marker")
    table.remove(engines.list, 1)
    check("love wins again after removal", tag(loveDir), "LÖVE")
    check("list is back to two", #engines.list, 2)

    -- 本应用自己的目录有 main.lua，引擎表认它是 LÖVE。
    -- 不把它排除在表外：finder（第 4 步）才拒绝启动这个目录。
    check("this app directory is love", tag(appDir), "LÖVE")

    print("OK " .. cases)
end

local ok, err = pcall(main)
cleanup()
if not ok then
    io.stderr:write(tostring(err), "\n")
    os.exit(1)
end
