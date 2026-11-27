-- lua5.1 tests/voicebutton-harness.lua
-- Temp directories only. No pad, no display, no device.

local src = debug.getinfo(1, "S").source
if src:sub(1, 1) == "@" then src = src:sub(2) end
local here = src:match("^(.*)/") or "."
local root = os.getenv("APPDIR") or here:match("^(.*)/tests$") or (here == "tests" and "." or here)
package.path = root .. "/?.lua;" .. package.path

local voicebutton = require("voicebutton")

local fails = 0
local NIL = {}

local function check(name, cond, detail)
    if cond then
        print("ok " .. name)
        return
    end
    fails = fails + 1
    local line = "FAIL " .. name
    if detail then line = line .. ": " .. tostring(detail) end
    io.stderr:write(line .. "\n")
end

local function sh_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function run(cmd)
    local r = os.execute(cmd)
    if r == true or r == 0 then return end
    error("command failed (" .. tostring(r) .. "): " .. cmd)
end

local function mkdtemp()
    local p = assert(io.popen("mktemp -d /tmp/rgds-voice.XXXXXX", "r"))
    local dir = p:read("*l")
    p:close()
    if not dir or dir == "" then error("mktemp -d returned nothing") end
    return dir
end

local function write_file(path, body)
    local fh = assert(io.open(path, "wb"))
    fh:write(body)
    fh:close()
end

local function mkdir(path)
    run("/bin/mkdir -p -- " .. sh_quote(path))
end

local EXPECTED = {
    [1] = "A", [2] = "B", [3] = "Y", [4] = "X",
    [5] = "L1", [6] = "R1", [7] = "SELECT", [8] = "START",
    [10] = "L3", [11] = "L2", [12] = "R2", [13] = "R3",
}

local function same_map()
    for n, name in pairs(EXPECTED) do
        if voicebutton.NAMES[n] ~= name then
            return false, "missing " .. tostring(n)
        end
    end
    for n, name in pairs(voicebutton.NAMES) do
        if EXPECTED[n] ~= name then
            return false, "extra " .. tostring(n) .. "=" .. tostring(name)
        end
    end
    return true
end

local function expect(name, result, want)
    for k, v in pairs(want) do
        local expected = v
        if v == NIL then expected = nil end
        if result[k] ~= expected then
            check(name, false, k .. " got " .. tostring(result[k]) .. " want " .. tostring(expected))
            return
        end
    end
    check(name, true)
end

local function run_cases(tmp)
    local ok, why = same_map()
    check("button names match the handheld map", ok, why)
    check("button 9 is not on this pad", voicebutton.NAMES[9] == nil)
    check("default is R1", voicebutton.DEFAULT_BUTTON == 6 and voicebutton.NAMES[6] == "R1")
    check("file name is rgds-voice", voicebutton.FILE_NAME == "rgds-voice")

    local samples = {
        {"1", 1}, {"2", 2}, {"3", 3}, {"4", 4},
        {"5", 5}, {"6", 6}, {"7", 7}, {"8", 8},
        {"10", 10}, {"11", 11}, {"12", 12}, {"13", 13},
    }
    for i = 1, #samples do
        local text, want = samples[i][1], samples[i][2]
        local got, err = voicebutton.parse(text)
        check("parse " .. text .. " is " .. voicebutton.NAMES[want], got == want and err == nil, err)
    end

    local none, none_err = voicebutton.parse("none")
    check("parse none", none == false and none_err == nil, none_err)

    local trimmed, trim_err = voicebutton.parse(" \t11\t ")
    check("parse trims spaces and tabs", trimmed == 11 and trim_err == nil, trim_err)

    local crlf, crlf_err = voicebutton.parse("12\r\n")
    check("parse CRLF", crlf == 12 and crlf_err == nil, crlf_err)

    local padded_none, padded_err = voicebutton.parse("  none  \n")
    check("parse padded none", padded_none == false and padded_err == nil, padded_err)

    local blank_lines, blank_err = voicebutton.parse("6\n\n  \n")
    check("parse ignores trailing blank lines", blank_lines == 6 and blank_err == nil, blank_err)

    local function parse_err(name, text, message)
        local got, err = voicebutton.parse(text)
        check(name, got == nil and err == message, tostring(got) .. " " .. tostring(err))
    end
    parse_err("parse empty", "", "voice file is empty")
    parse_err("parse whitespace", "  \n", "voice file is empty")
    parse_err("parse a second line", "6\n11\n", "voice file has more than one line")
    parse_err("parse NONE", "NONE", "voice file must be a button number or none")
    parse_err("parse a name", "L2", "voice file must be a button number or none")
    parse_err("parse 6.0", "6.0", "voice file must be a button number or none")
    parse_err("parse +6", "+6", "voice file must be a button number or none")
    parse_err("parse button 0", "0", "unknown button 0")
    parse_err("parse button 9", "9", "unknown button 9")
    parse_err("parse button 14", "14", "unknown button 14")
    parse_err("parse not text", nil, "voice file must be a button number or none")

    mkdir(tmp .. "/plain game")
    local plain = voicebutton.resolve(tmp .. "/plain game")
    expect("missing file in a directory is R1", plain, {
        button = 6, off = false, name = "R1", source = "default",
        path = tmp .. "/plain game/rgds-voice", err = NIL,
    })
    check("missing file still listens", voicebutton.listens(plain))
    check("missing file hint", voicebutton.hint(plain) == "HOLD R1 TALK")

    local sibling = tmp .. "/plain game.rgds-voice"
    write_file(sibling, "11\n")
    local ignored = voicebutton.resolve(tmp .. "/plain game")
    expect("a sibling file is not the directory mapping", ignored, {
        button = 6, source = "default", path = tmp .. "/plain game/rgds-voice",
    })

    mkdir(tmp .. "/moved")
    write_file(tmp .. "/moved/rgds-voice", "11\n")
    local moved = voicebutton.resolve(tmp .. "/moved/")
    expect("directory file with a trailing slash", moved, {
        button = 11, off = false, name = "L2", source = "file",
        path = tmp .. "/moved/rgds-voice", err = NIL,
    })
    check("L2 hint matches the bottom line", voicebutton.hint(moved) == "HOLD L2 TALK")
    check("L2 listens", voicebutton.listens(moved))

    write_file(tmp .. "/moved/rgds-voice", "6\n")
    local explicit = voicebutton.resolve(tmp .. "/moved")
    expect("an explicit 6 is the file, not the default", explicit, {
        button = 6, source = "file", name = "R1", off = false, err = NIL,
    })

    mkdir(tmp .. "/quiet")
    write_file(tmp .. "/quiet/rgds-voice", "none")
    local quiet = voicebutton.resolve(tmp .. "/quiet")
    expect("none turns voice off", quiet, {
        button = NIL, off = true, name = NIL, source = "file",
        path = tmp .. "/quiet/rgds-voice", err = NIL,
    })
    check("none does not listen", not voicebutton.listens(quiet))
    check("none hint", voicebutton.hint(quiet) == "VOICE OFF")

    write_file(tmp .. "/Game.love", "not really a zip")
    write_file(tmp .. "/Game.rgds-voice", "11\n")
    write_file(tmp .. "/Game.love.rgds-voice", "12\n")
    local love = voicebutton.resolve(tmp .. "/Game.love")
    expect(".love uses the file beside it", love, {
        button = 12, name = "R2", source = "file", off = false,
        path = tmp .. "/Game.love.rgds-voice", err = NIL,
    })

    os.remove(tmp .. "/Game.love.rgds-voice")
    local love_default = voicebutton.resolve(tmp .. "/Game.love")
    expect("a .love with no sibling file stays on R1", love_default, {
        button = 6, source = "default", path = tmp .. "/Game.love.rgds-voice",
    })

    mkdir(tmp .. "/Paks")
    write_file(tmp .. "/Paks/bor.pak", "pak")
    write_file(tmp .. "/Paks/bor.pak.rgds-voice", "none\r\n")
    local pak = voicebutton.resolve(tmp .. "/Paks/bor.pak")
    expect(".pak beside its voice file", pak, {
        button = NIL, off = true, source = "file",
        path = tmp .. "/Paks/bor.pak.rgds-voice", err = NIL,
    })

    write_file(tmp .. "/Paks/menu.pak", "menu")
    write_file(tmp .. "/Paks/menu.pak.rgds-voice", "13\n")
    local menu = voicebutton.resolve(tmp .. "/Paks/menu.pak")
    expect("menu.pak is still a pak path", menu, {
        button = 13, name = "R3", source = "file",
    })

    write_file(tmp .. "/UPPER.LOVE", "x")
    write_file(tmp .. "/UPPER.LOVE.rgds-voice", "  1  \n")
    local upper = voicebutton.resolve(tmp .. "/UPPER.LOVE")
    expect("uppercase .LOVE", upper, {button = 1, name = "A", source = "file"})

    write_file(tmp .. "/UPPER.PAK", "x")
    write_file(tmp .. "/UPPER.PAK.rgds-voice", "10\n")
    local upper_pak = voicebutton.resolve(tmp .. "/UPPER.PAK")
    expect("uppercase .PAK is L3", upper_pak, {button = 10, name = "L3", source = "file"})

    mkdir(tmp .. "/named.love")
    write_file(tmp .. "/named.love/rgds-voice", "5\n")
    write_file(tmp .. "/named.love.rgds-voice", "12\n")
    local named = voicebutton.resolve(tmp .. "/named.love")
    expect("a directory named like a .love reads the inside file", named, {
        button = 5, name = "L1", source = "file",
        path = tmp .. "/named.love/rgds-voice",
    })

    write_file(tmp .. "/notes.txt", "hello")
    local notes = voicebutton.resolve(tmp .. "/notes.txt")
    expect("a plain file is not a game path", notes, {
        button = NIL, off = false, source = NIL, path = NIL,
        err = "not a game directory or a .love/.pak file",
    })
    check("a plain file does not listen", not voicebutton.listens(notes))
    check("a plain file hint", voicebutton.hint(notes) == "VOICE FILE BAD")

    local gone = voicebutton.resolve(tmp .. "/no such game")
    expect("a missing game path is an error", gone, {
        button = NIL, off = false, source = NIL, path = NIL,
    })
    check("a missing game path is not R1", gone.button ~= 6 and gone.err ~= nil, gone.err)

    local empty_path = voicebutton.resolve("")
    expect("an empty path is an error", empty_path, {err = "game path required", button = NIL})
    local nil_path = voicebutton.resolve(nil)
    expect("a nil path is an error", nil_path, {err = "game path required", button = NIL})

    mkdir(tmp .. "/blank")
    write_file(tmp .. "/blank/rgds-voice", "")
    local blank = voicebutton.resolve(tmp .. "/blank")
    expect("an empty voice file is an error", blank, {
        button = NIL, off = false, source = "file", err = "voice file is empty",
        path = tmp .. "/blank/rgds-voice",
    })
    check("an empty voice file does not listen", not voicebutton.listens(blank))
    check("an empty voice file hint", voicebutton.hint(blank) == "VOICE FILE BAD")

    mkdir(tmp .. "/unknown")
    write_file(tmp .. "/unknown/rgds-voice", "9\n")
    local unknown = voicebutton.resolve(tmp .. "/unknown")
    expect("an unknown button is not R1", unknown, {
        button = NIL, source = "file", err = "unknown button 9", off = false,
    })

    mkdir(tmp .. "/multi")
    write_file(tmp .. "/multi/rgds-voice", "6\n11\n")
    local multi = voicebutton.resolve(tmp .. "/multi")
    expect("two buttons in one file is an error", multi, {
        err = "voice file has more than one line", button = NIL, source = "file",
    })

    mkdir(tmp .. "/voice-dir")
    mkdir(tmp .. "/voice-dir/rgds-voice")
    local voice_dir = voicebutton.resolve(tmp .. "/voice-dir")
    expect("a voice directory is an error", voice_dir, {
        err = "voice file is a directory", button = NIL, source = "file",
        path = tmp .. "/voice-dir/rgds-voice",
    })

    mkdir(tmp .. "/fifo-game")
    run("mkfifo " .. sh_quote(tmp .. "/fifo-game/rgds-voice"))
    local fifo = voicebutton.resolve(tmp .. "/fifo-game")
    expect("a fifo voice file is not opened", fifo, {
        err = "voice file is not a regular file", button = NIL, source = "file",
        path = tmp .. "/fifo-game/rgds-voice",
    })
    check("a fifo voice file does not listen", not voicebutton.listens(fifo))

    mkdir(tmp .. "/oversized")
    write_file(tmp .. "/oversized/rgds-voice", string.rep(" ", 300) .. "6\n")
    local oversized = voicebutton.resolve(tmp .. "/oversized")
    expect("an oversized voice file is an error", oversized, {
        err = "voice file is too large", button = NIL, off = false, source = "file",
        path = tmp .. "/oversized/rgds-voice",
    })
    check("an oversized voice file does not listen", not voicebutton.listens(oversized))

    local uid_pipe = io.popen("id -u")
    local uid = uid_pipe and uid_pipe:read("*l") or ""
    if uid_pipe then uid_pipe:close() end
    if uid ~= "0" then
        mkdir(tmp .. "/locked")
        local locked_path = tmp .. "/locked/rgds-voice"
        write_file(locked_path, "11\n")
        run("/bin/chmod 000 -- " .. sh_quote(locked_path))
        local locked = voicebutton.resolve(tmp .. "/locked")
        run("/bin/chmod 644 -- " .. sh_quote(locked_path))
        check("an unreadable voice file is not R1",
            locked.button == nil and locked.off == false and locked.source == "file"
                and locked.path == locked_path and type(locked.err) == "string"
                and locked.err ~= "",
            locked.err)
        check("an unreadable voice file does not listen", not voicebutton.listens(locked))
    end

    mkdir(tmp .. "/My Game")
    write_file(tmp .. "/My Game/rgds-voice", "4\n")
    local spaced = voicebutton.resolve(tmp .. "/My Game")
    expect("a game path with a space", spaced, {
        button = 4, name = "X", source = "file",
        path = tmp .. "/My Game/rgds-voice",
    })

    mkdir(tmp .. "/reread")
    write_file(tmp .. "/reread/rgds-voice", "5\n")
    local first = voicebutton.resolve(tmp .. "/reread")
    write_file(tmp .. "/reread/rgds-voice", "none\n")
    local second = voicebutton.resolve(tmp .. "/reread")
    expect("the first read sees the file", first, {button = 5, source = "file"})
    expect("a later read sees the new line", second, {off = true, button = NIL, source = "file"})

    mkdir(tmp .. "/real")
    write_file(tmp .. "/real/rgds-voice", "11\n")
    run("/bin/ln -s real " .. sh_quote(tmp .. "/linked"))
    local linked = voicebutton.resolve(tmp .. "/linked")
    expect("a symlink to a game directory", linked, {
        button = 11, name = "L2", source = "file",
        path = tmp .. "/linked/rgds-voice",
    })

    local where, where_err = voicebutton.mapping_path(tmp .. "/moved")
    check("mapping path of a directory", where == tmp .. "/moved/rgds-voice" and where_err == nil, where_err)
    local pack_path, pack_err = voicebutton.mapping_path(tmp .. "/Paks/bor.pak")
    check("mapping path of a pak", pack_path == tmp .. "/Paks/bor.pak.rgds-voice" and pack_err == nil, pack_err)

    check("hint of a non-table", voicebutton.hint(nil) == "VOICE FILE BAD")
    check("listens rejects a non-table", not voicebutton.listens(nil))
end

print("lua " .. _VERSION)
local tmp = mkdtemp()
local ok, err = xpcall(function() run_cases(tmp) end, debug.traceback)
run("/bin/rm -rf -- " .. sh_quote(tmp))
if not ok then
    io.stderr:write(tostring(err) .. "\n")
    os.exit(1)
end
if fails > 0 then
    io.stderr:write(fails .. " failed\n")
    os.exit(1)
end
print("OK")
