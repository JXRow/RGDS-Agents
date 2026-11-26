-- Finder list model. lua5.1 tests/finder-test.lua
-- Temp directories only. No LÖVE, no handheld, no engine table.

local src = debug.getinfo(1, "S").source
if src:sub(1, 1) == "@" then src = src:sub(2) end
local dir = src:match("^(.*)/[^/]+$") or "."
local root = dir:match("^(.*)/tests$") or (dir == "tests" and "." or dir)
package.path = root .. "/?.lua;" .. package.path

local finder = require("finder")

if arg and arg[1] == "--child" then
    local mode = arg[2]
    if mode == "file" then
        local got = finder.readWorkdir()
        if got ~= arg[3] then
            io.stderr:write("child file got " .. tostring(got) .. "\n")
            os.exit(1)
        end
    elseif mode == "default" then
        local got = finder.readWorkdir()
        if got ~= finder.DEFAULT_WORKDIR then
            io.stderr:write("child default got " .. tostring(got) .. "\n")
            os.exit(1)
        end
        if os.getenv("OPENCODE_WORKDIR") == nil or os.getenv("OPENCODE_WORKDIR") == "" then
            io.stderr:write("child expected OPENCODE_WORKDIR to be set and ignored\n")
            os.exit(1)
        end
    elseif mode == "explicit" then
        local got = finder.readWorkdir(arg[3])
        if got ~= arg[4] then
            io.stderr:write("child explicit got " .. tostring(got) .. "\n")
            os.exit(1)
        end
    else
        os.exit(2)
    end
    os.exit(0)
end

local fails, checks = 0, 0
local tmps = {}

local function shQuote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function ran(cmd)
    local status = os.execute(cmd)
    return status == 0 or status == true
end

local function check(cond, msg)
    checks = checks + 1
    if not cond then
        fails = fails + 1
        io.stderr:write("FAIL " .. msg .. "\n")
    end
end

local function cleanup()
    for i = 1, #tmps do
        ran("chmod -R u+rwx " .. shQuote(tmps[i]) .. " >/dev/null 2>&1")
        ran("rm -rf " .. shQuote(tmps[i]))
    end
end

local function tmp()
    local pipe = assert(io.popen("mktemp -d"))
    local path = pipe:read("*l")
    pipe:close()
    assert(path and path ~= "", "mktemp")
    tmps[#tmps + 1] = path
    return path
end

local function writeFile(path, body)
    local handle = assert(io.open(path, "wb"))
    handle:write(body or "")
    handle:close()
end

local function mkdir(path)
    assert(ran("mkdir -p " .. shQuote(path)), "mkdir " .. path)
end

local function link(target, path)
    assert(ran("ln -s " .. shQuote(target) .. " " .. shQuote(path)), "ln " .. path)
end

local function names(state)
    local out = {}
    for i, row in ipairs(state.rows) do
        out[i] = row.kind .. ":" .. row.name
    end
    return table.concat(out, ",")
end

local function rowNamed(state, name)
    for i, row in ipairs(state.rows) do
        if row.name == name then return row, i end
    end
end

local function selectName(state, name)
    for _ = 1, #state.rows + 1 do finder.up(state) end
    for _ = 1, #state.rows do
        local row = finder.selected(state)
        if row and row.name == name then return row end
        finder.down(state)
    end
    return nil
end

local function sameList(a, b)
    if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

local function main()
    check(finder.ROWS == 13, "13 visible rows")
    check(finder.DEFAULT_WORKDIR == "/mnt/mmc/Roms/APPS/RGDS-Agents", "default workdir")
    check(finder.WORKDIR_FILE == "/userdata/opencode/workdir", "workdir file path")

    local files = tmp()
    writeFile(files .. "/missing-not-created", "")
    ran("rm -f " .. shQuote(files .. "/missing-not-created"))
    check(finder.readWorkdir(files .. "/missing-not-created") == finder.DEFAULT_WORKDIR, "missing file")
    check(finder.readWorkdir(files) == finder.DEFAULT_WORKDIR, "directory is not a workdir file")

    writeFile(files .. "/empty", "")
    writeFile(files .. "/nl", "\n")
    writeFile(files .. "/blank", " \t \r\n")
    writeFile(files .. "/crlf-blank", "\r\n")
    writeFile(files .. "/spaces", "  /tmp/my games \t\r\n/ignored\n")
    writeFile(files .. "/cr-only", "  /tmp/foo\r")
    writeFile(files .. "/tabs", "\t/tmp/bar\t")
    writeFile(files .. "/relative", "games/demo\n")
    writeFile(files .. "/second", "/first\n/second\n")
    check(finder.readWorkdir(files .. "/empty") == finder.DEFAULT_WORKDIR, "empty file")
    check(finder.readWorkdir(files .. "/nl") == finder.DEFAULT_WORKDIR, "newline only")
    check(finder.readWorkdir(files .. "/blank") == finder.DEFAULT_WORKDIR, "whitespace line")
    check(finder.readWorkdir(files .. "/crlf-blank") == finder.DEFAULT_WORKDIR, "crlf blank")
    check(finder.readWorkdir(files .. "/spaces") == "/tmp/my games", "strip space tab cr and keep the first line")
    check(finder.readWorkdir(files .. "/cr-only") == "/tmp/foo", "strip a trailing cr")
    check(finder.readWorkdir(files .. "/tabs") == "/tmp/bar", "strip tabs")
    check(finder.readWorkdir(files .. "/relative") == "games/demo", "relative line stays relative")
    check(finder.readWorkdir(files .. "/second") == "/first", "second line is ignored")

    writeFile(files .. "/secret", "/tmp/secret-dir\n")
    assert(ran("chmod 000 " .. shQuote(files .. "/secret")))
    check(finder.readWorkdir(files .. "/secret") == finder.DEFAULT_WORKDIR, "unreadable file")
    assert(ran("chmod 644 " .. shQuote(files .. "/secret")))

    local function spawn(env, ...)
        local cmd = env .. " lua5.1 " .. shQuote(src)
        for i = 1, select("#", ...) do
            cmd = cmd .. " " .. shQuote(select(i, ...))
        end
        local status = os.execute(cmd)
        check(status == 0 or status == true, "child " .. tostring(select(1, ...)) .. " status " .. tostring(status))
    end
    writeFile(files .. "/from-file", "/tmp/from-file\n")
    writeFile(files .. "/other", "/tmp/other\n")
    spawn("OPENCODE_WORKDIR_FILE=" .. shQuote(files .. "/from-file") .. " OPENCODE_WORKDIR=/tmp/not-this",
        "--child", "file", "/tmp/from-file")
    spawn("OPENCODE_WORKDIR_FILE=" .. shQuote(files .. "/no-such-env") .. " OPENCODE_WORKDIR=/tmp/not-this",
        "--child", "default")
    spawn("OPENCODE_WORKDIR_FILE=" .. shQuote(files .. "/from-file") .. " OPENCODE_WORKDIR=/tmp/not-this",
        "--child", "explicit", files .. "/other", "/tmp/other")

    writeFile(files .. "/real-root", "")
    local listed = tmp()
    mkdir(listed .. "/sub")
    writeFile(files .. "/listed", listed .. "\n")
    local opened = finder.open({ file = files .. "/listed" })
    check(opened.root == listed, "open reads the workdir file")
    check(opened.error == nil, "open listed directory")
    check(rowNamed(opened, "sub") ~= nil, "open shows the child")

    local missingFile = finder.open({ file = files .. "/no-such-open" })
    check(missingFile.root == finder.DEFAULT_WORKDIR, "missing workdir file uses the default")
    check(missingFile.error == "missing", "default directory is absent here")
    check(finder.kindLine(missingFile) == "missing", "kind line reports missing")
    check(missingFile.cursor == 0 and missingFile.scroll == 0, "missing directory has no cursor")
    check(#finder.window(missingFile).rows == 0, "missing window is empty")

    writeFile(files .. "/blank-open", " \n")
    local blankOpen = finder.open({ file = files .. "/blank-open" })
    check(blankOpen.root == finder.DEFAULT_WORKDIR, "blank workdir file uses the default")

    local relative = finder.open({ root = "no/such/relative/finder" })
    check(relative.root:sub(1, 1) == "/", "relative root is made absolute")
    check(relative.root:sub(-#"no/such/relative/finder") == "no/such/relative/finder", "relative tail kept")
    check(relative.error == "missing", "relative missing root")

    local dotted = tmp()
    local dottedState = finder.open({ root = dotted .. "/./" })
    check(dottedState.root == dotted, "trailing slash and dot are normalized")
    check(dottedState.error == nil, "normalized root lists")
    check(dottedState.path == dotted and dottedState.rel == "", "open starts at the root")
    check(finder.kindLine(dottedState) == "empty", "empty root says empty")
    check(dottedState.visible == 13, "visible count is 13")
    local cursor, scroll = dottedState.cursor, dottedState.scroll
    finder.up(dottedState)
    finder.down(dottedState)
    check(dottedState.cursor == cursor and dottedState.scroll == scroll, "empty list ignores up and down")
    check(finder.back(dottedState).op == "none", "B at an empty root does nothing")
    check(dottedState.path == dotted, "B leaves the path")
    check(finder.confirm(dottedState).op == "none", "A on an empty root does nothing")

    local order = tmp()
    mkdir(order .. "/.hidden")
    mkdir(order .. "/A")
    mkdir(order .. "/a")
    mkdir(order .. "/b")
    writeFile(order .. "/b/z", "z")
    writeFile(order .. "/10", "")
    writeFile(order .. "/2", "")
    writeFile(order .. "/B", "")
    local ordered = finder.open({ root = order })
    -- Directories and files cannot share a name, so the capital file is B.
    -- Directory order A, a, b is still byte order, and 10 before 2 is not numeric order.
    check(names(ordered) == "dir:.hidden,dir:A,dir:a,dir:b,file:10,file:2,file:B",
        "byte order dirs then files, got " .. names(ordered))
    check(ordered.rows[1].name ~= "..", "root has no ..")
    local hidden = rowNamed(ordered, ".hidden")
    check(hidden.slash and not hidden.game and not hidden.dim and hidden.empty, ".hidden is an empty folder")
    check(selectName(ordered, ".hidden") ~= nil, "select .hidden")
    check(finder.kindLine(ordered) == "empty", "empty folder kind")
    check(selectName(ordered, "b") ~= nil, "select b")
    check(finder.kindLine(ordered) == "folder", "folder with a child")
    local folderB = rowNamed(ordered, "b")
    check(folderB and folderB.slash, "plain directory has a slash flag")
    local enteredB = finder.confirm(ordered)
    check(enteredB.op == "enter" and enteredB.name == "b", "A enters a folder")
    check(ordered.rel == "b", "relative path is the folder")
    check(names(ordered) == "up:..,file:z", "inside b: .. then the file, got " .. names(ordered))
    check(finder.selected(ordered).name == "..", "enter selects the first row")
    check(finder.kindLine(ordered) == "folder", ".. is a folder")
    check(finder.selected(ordered).slash == false and finder.selected(ordered).dim == false, ".. has no slash and is not dim")
    local backFromB = finder.back(ordered)
    check(backFromB.op == "leave" and backFromB.name == "b", "B leaves and names the child")
    check(ordered.rel == "" and ordered.path == order, "back at the root")
    check(finder.selected(ordered).name == "b", "back reselects the folder")
    check(finder.back(ordered).op == "none", "B at the root does nothing")
    check(finder.selected(ordered).name == "b" and ordered.path == order, "root B keeps the selection")

    check(selectName(ordered, "a") ~= nil, "select empty a")
    check(finder.right(ordered).op == "enter", "right enters a folder")
    check(finder.selected(ordered).kind == "up", "right lands on ..")
    check(finder.right(ordered).op == "leave", "right on .. leaves")
    check(finder.selected(ordered).name == "a", "leave reselects a")
    check(selectName(ordered, "a") ~= nil, "select a again")
    finder.confirm(ordered)
    check(finder.confirm(ordered).op == "leave", "A on .. leaves")

    check(selectName(ordered, "10") ~= nil, "select file 10")
    local fileRow = finder.selected(ordered)
    check(fileRow.dim and not fileRow.game and not fileRow.slash and fileRow.kind == "file", "plain file is dim")
    check(finder.kindLine(ordered) == "not a game", "plain file kind")
    local pathBefore = ordered.path
    check(finder.confirm(ordered).op == "none", "A on a plain file does nothing")
    check(finder.right(ordered).op == "none", "right on a file does nothing")
    check(ordered.path == pathBefore, "file actions stay put")

    -- "10" before "2" is byte order, not numeric order. Already in the name list.
    check(rowNamed(ordered, "10") and rowNamed(ordered, "2"), "both digit names exist")
    local index10 = select(2, rowNamed(ordered, "10"))
    local index2 = select(2, rowNamed(ordered, "2"))
    check(index10 < index2, "byte order puts 10 before 2")

    local scroll = tmp()
    for i = 1, 16 do
        writeFile(string.format("%s/n%02d", scroll, i), "")
    end
    local scrolled = finder.open({ root = scroll })
    check(#scrolled.rows == 16 and scrolled.cursor == 1 and scrolled.scroll == 1, "scroll list starts at the top")
    check(finder.kindLine(scrolled) == "not a game", "file rows are not games")
    for _ = 1, 12 do finder.down(scrolled) end
    check(scrolled.cursor == 13 and scrolled.scroll == 1, "13th row is still on the first page")
    local page = finder.window(scrolled)
    check(#page.rows == 13 and page.cursor == 13, "window is 13 rows with the cursor on the last")
    check(page.rows[1] == scrolled.rows[1] and page.rows[1].name == "n01", "window shares the row tables")
    check(page.rows[13].name == "n13", "first page ends at n13")
    finder.down(scrolled)
    check(scrolled.cursor == 14 and scrolled.scroll == 2, "the next row scrolls")
    page = finder.window(scrolled)
    check(page.rows[1].name == "n02" and page.cursor == 13 and page.rows[13].name == "n14", "selection stays on the last visible row")
    for _ = 1, 20 do finder.down(scrolled) end
    check(scrolled.cursor == 16 and scrolled.scroll == 4, "down stops on the last row")
    local endCursor, endScroll = scrolled.cursor, scrolled.scroll
    finder.down(scrolled)
    check(scrolled.cursor == endCursor and scrolled.scroll == endScroll, "down at the end is a no-op")
    page = finder.window(scrolled)
    check(#page.rows == 13 and page.rows[1].name == "n04" and page.rows[13].name == "n16" and page.cursor == 13,
        "last page is n04 through n16")
    for _ = 1, 12 do finder.up(scrolled) end
    check(scrolled.cursor == 4 and scrolled.scroll == 4, "up keeps the cursor at the top of the window")
    finder.up(scrolled)
    check(scrolled.cursor == 3 and scrolled.scroll == 3, "the next up scrolls")
    for _ = 1, 20 do finder.up(scrolled) end
    check(scrolled.cursor == 1 and scrolled.scroll == 1, "up stops on the first row")
    finder.up(scrolled)
    check(scrolled.cursor == 1 and scrolled.scroll == 1, "up at the top is a no-op")

    for _ = 1, 20 do finder.down(scrolled) end
    writeFile(scroll .. "/n00", "")
    finder.refresh(scrolled)
    check(finder.selected(scrolled).name == "n16", "refresh keeps the selected name")
    check(scrolled.cursor == 17 and scrolled.scroll == 5, "refresh reveals the kept name, got cursor "
        .. tostring(scrolled.cursor) .. " scroll " .. tostring(scrolled.scroll))
    ran("rm -f " .. shQuote(scroll .. "/n16"))
    finder.refresh(scrolled)
    check(finder.selected(scrolled) == nil or finder.selected(scrolled).name ~= "n16", "deleted name is gone")
    check(scrolled.cursor >= 1 and scrolled.cursor <= #scrolled.rows, "cursor stays in range after a delete")
    check(#scrolled.rows == 16, "one file removed")

    local walk = tmp()
    for i = 1, 16 do
        mkdir(string.format("%s/d%02d", walk, i))
    end
    local walked = finder.open({ root = walk })
    check(selectName(walked, "d16") ~= nil, "select d16")
    check(walked.cursor == 16 and walked.scroll == 4, "d16 is on the last page")
    local entered = finder.right(walked)
    check(entered.op == "enter" and walked.rel == "d16", "entered d16")
    check(names(walked) == "up:..", "empty folder shows only .., got " .. names(walked))
    check(walked.cursor == 1 and walked.scroll == 1, "enter resets the cursor")
    local left = finder.back(walked)
    check(left.op == "leave" and finder.selected(walked).name == "d16", "back reselects d16")
    check(walked.cursor == 16 and walked.scroll == 4, "back puts d16 back in the window")
    check(finder.back(walked).op == "none" and walked.path == walk, "left at the root does nothing")

    local quoted = tmp() .. "/my work"
    mkdir(quoted)
    mkdir(quoted .. "/a'b")
    writeFile(quoted .. "/a'b/x", "x")
    mkdir(quoted .. "/my games")
    writeFile(quoted .. "/-n", "")
    writeFile(quoted .. "/a\"$b", "")
    local quotedState = finder.open({ root = quoted })
    check(names(quotedState) == "dir:a'b,dir:my games,file:-n,file:a\"$b",
        "names with quotes, spaces, and a dash, got " .. names(quotedState))
    check(finder.confirm(selectName(quotedState, "my games") and quotedState or quotedState).op == "enter", "enter a spaced name")
    check(quotedState.rel == "my games", "relative path keeps the space")
    check(finder.back(quotedState).name == "my games", "back from a spaced name")
    check(selectName(quotedState, "a'b") ~= nil, "select quoted name")
    check(finder.right(quotedState).op == "enter", "enter a quoted name")
    check(names(quotedState) == "up:..,file:x", "inside the quoted folder, got " .. names(quotedState))
    finder.back(quotedState)

    local games = tmp()
    local appDir = games .. "/RGDS-Agents"
    mkdir(appDir)
    writeFile(appDir .. "/main.lua", "print('app')\n")
    mkdir(games .. "/RGDS-Agents-extra")
    writeFile(games .. "/RGDS-Agents-extra/main.lua", "print('extra')\n")
    link(appDir, games .. "/linked-app")
    mkdir(games .. "/Game")
    writeFile(games .. "/Game/main.lua", "print('game')\n")
    link("/etc", games .. "/Game/out")
    mkdir(games .. "/BrokenEngine")
    writeFile(games .. "/demo.love", "not-a-zip")
    writeFile(games .. "/readme.txt", "hi")
    local calls = {}
    local function hasMain(list)
        if not list then return false end
        for i = 1, #list do
            if list[i] == "main.lua" then return true end
        end
        return false
    end
    local given = nil
    local function engineOf(path, kind, list)
        calls[#calls + 1] = { path = path, kind = kind, names = list }
        if kind == "file" then
            check(list == nil, "a file is asked with nil names: " .. path)
        end
        if kind == "dir" and path:match("/BrokenEngine$") then
            return {
                id = "openbor", label = "OpenBOR", startable = false,
                hint = "install OpenBOR", start = "/engines/openbor/start.sh",
            }
        end
        if kind == "dir" and hasMain(list) then
            given = {
                id = "love", label = "LÖVE", startable = true,
                start = "/engines/love/start.sh", stop = "SIGTERM", edits = "lua files",
            }
            return given
        end
        if kind == "file" and path:sub(-5) == ".love" then
            return { id = "love", label = "LÖVE", startable = true, start = "/engines/love/start.sh" }
        end
        return nil
    end
    local library = finder.open({ root = games, appDir = appDir, engineOf = engineOf })
    check(library.appDir == appDir, "appDir is the resolved app path")
    local appRow = rowNamed(library, "RGDS-Agents")
    check(appRow and appRow.game == false and appRow.engine == nil and appRow.startable == false, "the app directory is not a game")
    check(appRow.slash and appRow.kind == "dir" and appRow.tag == nil, "the app directory is a plain folder")
    local linkRow = rowNamed(library, "linked-app")
    check(linkRow and linkRow.game == false and linkRow.engine == nil, "a symlink to the app directory is not a game")
    local extra = rowNamed(library, "RGDS-Agents-extra")
    check(extra and extra.game and extra.startable and extra.tag == "LÖVE" and extra.slash == false, "a sibling with main.lua is a game")
    check(extra.engine.start == "/engines/love/start.sh" and extra.engine.edits == "lua files", "engine fields pass through")
    check(extra.engine ~= given, "the row keeps its own engine table")
    local game = rowNamed(library, "Game")
    check(game and game.startable and game.tag == "LÖVE", "Game is startable")
    local gameCall = nil
    for i = 1, #calls do
        if calls[i].path == games .. "/Game" then gameCall = calls[i] end
    end
    check(gameCall and gameCall.kind == "dir" and sameList(gameCall.names, { "main.lua", "out" }),
        "engineOf sees top-level names, including one that points outside")
    local loveCall = nil
    for i = 1, #calls do
        if calls[i].path == games .. "/demo.love" then loveCall = calls[i] end
    end
    check(loveCall and loveCall.kind == "file" and loveCall.names == nil, "a file has nil names")

    local broken = rowNamed(library, "BrokenEngine")
    check(broken and broken.game and broken.startable == false and broken.tag == "OpenBOR" and broken.dim == false,
        "a missing binary is tagged and not startable")
    check(selectName(library, "BrokenEngine") ~= nil, "select the broken engine")
    check(finder.kindLine(library) == "install OpenBOR", "kind line is the install hint")
    local stayed = library.path
    check(finder.confirm(library).op == "none" and library.path == stayed, "A does not start or enter a row that cannot start")
    check(finder.right(library).op == "enter" and library.rel == "BrokenEngine", "right still enters that folder")
    finder.back(library)

    check(selectName(library, "readme.txt") ~= nil, "select readme")
    check(finder.selected(library).dim and finder.kindLine(library) == "not a game", "readme is not a game")
    check(finder.confirm(library).op == "none", "A ignores readme")

    check(selectName(library, "demo.love") ~= nil, "select demo.love")
    local started = finder.confirm(library)
    check(started.op == "start" and started.path == games .. "/demo.love", "A on a game file starts it")
    check(started.engine.id == "love" and started.engine.start == "/engines/love/start.sh", "start carries the engine")
    check(library.path == games and finder.selected(library).name == "demo.love", "start does not change the folder")
    check(finder.right(library).op == "none", "right does not start a file")

    check(selectName(library, "RGDS-Agents-extra") ~= nil, "select the extra game")
    local startDir = finder.confirm(library)
    check(startDir.op == "start" and startDir.path == games .. "/RGDS-Agents-extra", "A on a game folder starts it")
    check(library.rel == "", "starting a folder does not enter it")
    check(finder.right(library).op == "enter" and library.rel == "RGDS-Agents-extra", "right enters a game folder")
    check(rowNamed(library, "out") == nil, "still outside")
    finder.back(library)

    check(selectName(library, "Game") ~= nil, "select Game")
    check(finder.right(library).op == "enter", "enter Game")
    check(rowNamed(library, "out") == nil, "a symlink to /etc is not shown")
    check(rowNamed(library, "main.lua") and rowNamed(library, "main.lua").dim, "main.lua inside a game is a plain file")
    check(library.path == games .. "/Game", "path stayed under the work root")
    finder.back(library)

    check(selectName(library, "RGDS-Agents") ~= nil, "select the app directory")
    check(finder.kindLine(library) == "folder", "the app directory's kind is folder")
    local intoApp = finder.confirm(library)
    check(intoApp.op == "enter" and intoApp.path == appDir, "A enters the app directory instead of starting it")
    check(finder.back(library).op == "leave", "leave the app directory")

    check(selectName(library, "linked-app") ~= nil, "select the app symlink")
    check(finder.confirm(library).op == "enter", "the app symlink enters")
    check(library.rootReal == games, "still inside the work root")
    finder.back(library)

    local asApp = tmp()
    writeFile(asApp .. "/main.lua", "print('self')\n")
    mkdir(asApp .. "/Game")
    writeFile(asApp .. "/Game/main.lua", "print('nested')\n")
    local selfRoot = finder.open({
        root = asApp,
        appDir = asApp,
        engineOf = engineOf,
    })
    check(selfRoot.path == asApp, "the app directory can be the work root")
    local nested = rowNamed(selfRoot, "Game")
    check(nested and nested.startable, "a game inside the app directory is still startable")
    check(rowNamed(selfRoot, "main.lua") and rowNamed(selfRoot, "main.lua").game == false, "the app's own main.lua is not a game row")
    local anyRoot = false
    for i = 1, #selfRoot.rows do
        if selfRoot.rows[i].path == asApp and selfRoot.rows[i].startable then anyRoot = true end
    end
    check(not anyRoot, "the work root is not itself a startable row")

    local escape = tmp()
    mkdir(escape .. "/inside")
    writeFile(escape .. "/inside/file.txt", "f")
    link(escape .. "/inside", escape .. "/alias")
    link("/etc", escape .. "/out")
    link("/etc/passwd", escape .. "/outf")
    link(escape .. "/inside/file.txt", escape .. "/stay")
    link("..", escape .. "/up")
    link("/no/such/finder-target", escape .. "/broken")
    local escaped = finder.open({ root = escape })
    check(names(escaped) == "dir:alias,dir:inside,file:broken,file:stay",
        "outside symlinks are hidden, got " .. names(escaped))
    check(rowNamed(escaped, "out") == nil and rowNamed(escaped, "outf") == nil and rowNamed(escaped, "up") == nil,
        "parent and /etc links are absent")
    check(selectName(escaped, "alias") ~= nil, "select alias")
    check(finder.right(escaped).op == "enter" and escaped.path == escape .. "/alias", "enter keeps the logical path")
    check(escaped.rootReal == escape, "containment root is the work directory")
    check(rowNamed(escaped, "file.txt") ~= nil, "the alias lists the target")
    check(finder.back(escaped).name == "alias" and escaped.path == escape, "back from the alias stays in the root")
    check(selectName(escaped, "broken") ~= nil, "select the broken symlink")
    check(finder.selected(escaped).kind == "file" and finder.selected(escaped).dim, "a broken symlink is a plain file")
    check(finder.right(escaped).op == "none" and escaped.path == escape, "a broken symlink is not entered")
    check(selectName(escaped, "stay") ~= nil, "select the inside file link")
    check(finder.right(escaped).op == "none", "right does not open a file link")

    local real = tmp()
    mkdir(real .. "/child")
    writeFile(real .. "/child/k", "k")
    link("/etc", real .. "/out")
    local linkRoot = tmp() .. "/link"
    link(real, linkRoot)
    local via = finder.open({ root = linkRoot })
    check(via.root == linkRoot and via.rootReal == real, "a symlink work root keeps its logical path")
    check(rowNamed(via, "child") ~= nil and rowNamed(via, "out") == nil, "children of the target stay inside")
    check(finder.right(selectName(via, "child") and via or via).op == "enter", "enter through the symlink root")
    check(via.path == linkRoot .. "/child" and via.rel == "child", "trail stays on the logical root")
    check(rowNamed(via, "k") ~= nil, "the child lists")
    check(finder.back(via).op == "leave" and via.path == linkRoot, "back returns to the symlink, not its parent")

    local blocked = tmp()
    mkdir(blocked .. "/secret")
    writeFile(blocked .. "/secret/x", "x")
    assert(ran("chmod 000 " .. shQuote(blocked .. "/secret")))
    local unreadable = finder.open({ root = blocked .. "/secret" })
    check(unreadable.error == "unreadable", "unreadable directory")
    check(#unreadable.rows == 0 and finder.kindLine(unreadable) == "unreadable", "unreadable kind line")
    assert(ran("chmod 755 " .. shQuote(blocked .. "/secret")))

    writeFile(blocked .. "/notdir", "x")
    local notDir = finder.open({ root = blocked .. "/notdir" })
    check(notDir.error == "not a directory", "a file is not a work root")
    check(finder.kindLine(notDir) == "not a directory", "kind line names that")

    local gone = finder.open({ root = blocked .. "/gone" })
    check(gone.error == "missing" and finder.up(gone) == nil, "missing root")

    local one = tmp()
    local two = tmp()
    writeFile(one .. "/only", "")
    writeFile(two .. "/other", "")
    local leftState = finder.open({ root = one })
    local rightState = finder.open({ root = two })
    finder.down(leftState)
    check(rightState.cursor == 1 and finder.selected(rightState).name == "other", "two finders do not share a cursor")

    local keep = tmp()
    writeFile(keep .. "/a", "")
    writeFile(keep .. "/b", "")
    writeFile(keep .. "/c", "")
    local kept = finder.open({ root = keep })
    finder.down(kept)
    check(finder.selected(kept).name == "b", "cursor on b")
    writeFile(keep .. "/d", "")
    finder.refresh(kept)
    check(finder.selected(kept).name == "b", "refresh keeps b")
    check(names(kept) == "file:a,file:b,file:c,file:d", "refresh sees d, got " .. names(kept))
    ran("rm -f " .. shQuote(keep .. "/b"))
    finder.refresh(kept)
    check(names(kept) == "file:a,file:c,file:d", "refresh drops b, got " .. names(kept))
    check(finder.selected(kept).name == "c", "the cursor stays at the same index")

    local copyRoot = tmp()
    writeFile(copyRoot .. "/a.love", "x")
    local shared = { id = "love", label = "LÖVE", startable = true, start = "/engines/love/start.sh" }
    local copied = finder.open({
        root = copyRoot,
        engineOf = function() return shared end,
    })
    shared.label = "changed"
    shared.startable = false
    local copiedRow = rowNamed(copied, "a.love")
    check(copiedRow.tag == "LÖVE" and copiedRow.startable, "the list copies the engine record")
    check(copiedRow.engine ~= shared, "the copy is a different table")
end

local ok, err = pcall(main)
cleanup()
if not ok then
    io.stderr:write(tostring(err) .. "\n")
    os.exit(1)
end
if fails > 0 then
    io.stderr:write(fails .. " failed out of " .. checks .. "\n")
    os.exit(1)
end
print("OK " .. checks)
