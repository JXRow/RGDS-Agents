-- Per-game voice button. Pure Lua: no LÖVE, no pad, no pid file.
--
-- A game directory carries one line in rgds-voice.
-- A .love or .pak file carries that line in <file>.rgds-voice beside it.
-- The line is a joystick button in this app's numbering, or none.
-- Numbering matches main.lua BUTTONS (RetroArch udev map, plus one):
--   1 A, 2 B, 3 Y, 4 X, 5 L1, 6 R1, 7 SELECT, 8 START,
--   10 L3, 11 L2, 12 R2, 13 R3.
-- No file means R1, button 6. none means voice is off for that game.
-- A file that is present but not a known button or none is an error.
-- The button stays unset, so a game that uses R1 keeps it.
--
-- Wiring, once step 7 has a live game path from the pid file:
--   local choice = voicebutton.resolve(game_path)
--   local clause = voicebutton.hint(choice)
-- While that game runs, joystick press and release act on choice.button
-- only when voicebutton.listens(choice). Every other button is the game's.
-- The finder, with no game running, keeps DEFAULT_BUTTON and reads no file.
-- The bottom line joins the engine label, the game name, and this clause.

local M = {}

M.DEFAULT_BUTTON = 6
M.FILE_NAME = "rgds-voice"

M.NAMES = {
    [1] = "A", [2] = "B", [3] = "Y", [4] = "X",
    [5] = "L1", [6] = "R1", [7] = "SELECT", [8] = "START",
    [10] = "L3", [11] = "L2", [12] = "R2", [13] = "R3",
}

-- strerror is localized, so a missing file is recognized by comparing
-- the tail of the error with a probe open, not by an English sentence.
local missing_tail

local function absent_tail()
    if missing_tail ~= nil then return missing_tail end
    local probe = "/rgds-voice-missing-probe"
    local _, err = io.open(probe, "rb")
    local prefix = probe .. ": "
    if type(err) == "string" and err:sub(1, #prefix) == prefix then
        missing_tail = ": " .. err:sub(#prefix + 1)
    else
        missing_tail = false
    end
    return missing_tail
end

local function is_absent(err)
    if type(err) ~= "string" then return false end
    local tail = absent_tail()
    if tail and err:sub(-#tail) == tail then return true end
    return err:find("No such file or directory", 1, true) ~= nil
end

local function strip_slashes(path)
    if path == "/" then return "/" end
    local stripped = path:gsub("/+$", "")
    if stripped == "" then return "/" end
    return stripped
end

local function is_pack_file(path)
    local base = path:match("([^/]+)$") or path
    local ext = base:match("%.([^./]+)$")
    if not ext then return false end
    ext = ext:lower()
    return ext == "love" or ext == "pak"
end

-- "dir", "file", or nil plus an error. A directory is path/., which does
-- not depend on the wording of a read error.
local function kind_of(path)
    local dotted = io.open(path .. "/.", "rb")
    if dotted then
        dotted:close()
        return "dir"
    end
    local fh, err = io.open(path, "rb")
    if fh then
        fh:close()
        return "file"
    end
    return nil, err or "cannot open game path"
end

local function pack(button, off, name, source, path, err)
    return {
        button = button,
        off = off and true or false,
        name = name,
        source = source,
        path = path,
        err = err,
    }
end

function M.mapping_path(game_path)
    if type(game_path) ~= "string" or game_path == "" then
        return nil, "game path required"
    end
    local path = strip_slashes(game_path)
    local kind, err = kind_of(path)
    if not kind then return nil, err end
    if kind == "dir" then
        return path .. "/" .. M.FILE_NAME
    end
    if is_pack_file(path) then
        return path .. "." .. M.FILE_NAME
    end
    return nil, "not a game directory or a .love/.pak file"
end

-- Returns a button number, false for none, or nil plus an error.
function M.parse(text)
    if type(text) ~= "string" then
        return nil, "voice file must be a button number or none"
    end
    text = text:gsub("\r\n", "\n")
    text = text:gsub("\r", "\n")
    local nl = text:find("\n", 1, true)
    local first, rest
    if not nl then
        first = text
        rest = ""
    else
        first = text:sub(1, nl - 1)
        rest = text:sub(nl + 1)
    end
    if rest:find("%S") then
        return nil, "voice file has more than one line"
    end
    local token = first:match("^%s*(.-)%s*$")
    if token == "" then
        return nil, "voice file is empty"
    end
    if token == "none" then
        return false
    end
    if not token:match("^%d+$") then
        return nil, "voice file must be a button number or none"
    end
    local n = tonumber(token)
    if not M.NAMES[n] then
        return nil, "unknown button " .. token
    end
    return n
end

function M.resolve(game_path)
    local path, err = M.mapping_path(game_path)
    if not path then
        return pack(nil, false, nil, nil, nil, err)
    end
    local as_dir = io.open(path .. "/.", "rb")
    if as_dir then
        as_dir:close()
        return pack(nil, false, nil, "file", path, "voice file is a directory")
    end
    local fh, oerr = io.open(path, "rb")
    if not fh then
        if is_absent(oerr) then
            local button = M.DEFAULT_BUTTON
            return pack(button, false, M.NAMES[button], "default", path, nil)
        end
        return pack(nil, false, nil, "file", path, oerr or "cannot open voice file")
    end
    local body, rerr = fh:read("*a")
    fh:close()
    if body == nil then
        return pack(nil, false, nil, "file", path, rerr or "cannot read voice file")
    end
    local button, perr = M.parse(body)
    if perr then
        return pack(nil, false, nil, "file", path, perr)
    end
    if button == false then
        return pack(nil, true, nil, "file", path, nil)
    end
    return pack(button, false, M.NAMES[button], "file", path, nil)
end

function M.listens(result)
    return type(result) == "table"
        and result.err == nil
        and result.off ~= true
        and type(result.button) == "number"
end

-- The voice clause of the bottom hint. The engine label and the game
-- name come from the pid file, not from here.
function M.hint(result)
    if type(result) ~= "table" or result.err then
        return "VOICE FILE BAD"
    end
    if result.off or type(result.button) ~= "number" then
        return "VOICE OFF"
    end
    local name = result.name or M.NAMES[result.button]
    if not name then return "VOICE FILE BAD" end
    return "HOLD " .. name .. " TALK"
end

return M
