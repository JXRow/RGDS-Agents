-- lua5.1 tests/targets-hit.lua
-- Bottom-panel targets. No LÖVE, no device.
-- A target fires when a finger that went down lifts inside it.
-- STOP GAME is present only while a game is running.

local src = debug.getinfo(1, "S").source
if src:sub(1, 1) == "@" then src = src:sub(2) end
local here = src:match("^(.*)/") or "."
local root = here:match("^(.*)/tests$") or (here == "tests" and "." or here)
package.path = root .. "/?.lua;" .. package.path

local targets = require("targets")

local failures = 0
local checks = 0

local function check(cond, msg)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        io.stderr:write("FAIL: " .. msg .. "\n")
    end
end

local function same(t, id, op, label, x, y, w, h)
    check(type(t) == "table", id .. " is a target")
    if type(t) ~= "table" then return end
    check(t.id == id, id .. " id")
    check(t.op == op, id .. " op, got " .. tostring(t.op))
    check(t.label == label, id .. " label, got " .. tostring(t.label))
    check(t.x == x and t.y == y and t.w == w and t.h == h,
        string.format("%s rect %s,%s %sx%s", id, tostring(t.x), tostring(t.y), tostring(t.w), tostring(t.h)))
    check(t.w >= 96 and t.h >= 48, id .. " is at least 96x48")
end

local function ids(list)
    local out = {}
    for i = 1, #list do out[i] = list[i].id end
    return table.concat(out, ",")
end

-- Plan: server row 12,8 616x48. STOP GAME is 200x48 at the right end.
local ROW_X, ROW_Y, ROW_W, ROW_H = 12, 8, 616, 48
local STOP_W = 200
local ACTION_W = ROW_W - STOP_W
local STOP_X = ROW_X + ACTION_W

local CHAT_X, CHAT_Y = 320, 200
local TOOL_X, TOOL_Y = 320, 70
local MIC_X, MIC_Y = 320, 426
local HINT_X, HINT_Y = 320, 464

local idle = targets.layout({action = "start"})
check(#idle == 1, "no game: one target, got " .. #idle)
same(idle[1], "action", "start", "START", ROW_X, ROW_Y, ROW_W, ROW_H)
check(ids(idle) == "action", "no game: STOP GAME is absent")

local restart = targets.layout({action = "restart"})
same(restart[1], "action", "restart", "RESTART", ROW_X, ROW_Y, ROW_W, ROW_H)

local wizard = targets.layout({action = "wizard"})
same(wizard[1], "action", "wizard", "WIZARD", ROW_X, ROW_Y, ROW_W, ROW_H)

check(#targets.layout({action = nil}) == 0, "no action target for nil")
for _, action in ipairs({"", "browse", "stop"}) do
    local list = targets.layout({action = action})
    check(#list == 0, "no action target for " .. tostring(action) .. ", got " .. ids(list))
end

check(#targets.layout(nil) == 0, "nil state has no targets")
check(#targets.layout({}) == 0, "empty state has no targets")

local both = targets.layout({action = "restart", game = true})
check(#both == 2, "game running: action and STOP GAME, got " .. ids(both))
same(both[1], "action", "restart", "RESTART", ROW_X, ROW_Y, ACTION_W, ROW_H)
same(both[2], "stop", "stop", "STOP GAME", STOP_X, ROW_Y, STOP_W, ROW_H)
check(both[1].x + both[1].w == both[2].x, "action and STOP GAME meet")

local stopOnly = targets.layout({game = true})
check(#stopOnly == 1 and stopOnly[1].id == "stop", "game with no server action: only STOP GAME")
same(stopOnly[1], "stop", "stop", "STOP GAME", STOP_X, ROW_Y, STOP_W, ROW_H)

check(ids(targets.layout({action = "start", game = 1})) == "action",
    "only boolean true shows STOP GAME")
check(ids(targets.layout({action = "start", game = false})) == "action",
    "game false hides STOP GAME")

local again = targets.layout({action = "start"})
check(#again == 1 and again[1].id == "action" and again[1].w == ROW_W,
    "layout does not keep the previous game")

local function press(list, gesture, phase, x, y)
    local fired, nextGesture = targets.step(list, gesture, phase, x, y)
    return fired, nextGesture
end

local function lift(list, x, y)
    local fired, gesture = press(list, nil, true, x, y)
    check(fired == nil, "press does not fire")
    return press(list, gesture, false, x, y)
end

local fired, gesture = lift(idle, 320, 32)
check(fired == idle[1], "lift inside the server action fires that target")
check(gesture.down == false, "lift releases the finger")

fired, gesture = press(idle, nil, true, 320, 32)
fired, gesture = press(idle, gesture, "move", 340, 40)
check(fired == nil, "a move does not fire")
fired, gesture = press(idle, gesture, false, 340, 40)
check(fired == idle[1] and gesture.down == false, "lift after a move inside still fires once")

for _, point in ipairs({
    {CHAT_X, CHAT_Y, "chat log"},
    {TOOL_X, TOOL_Y, "tool line"},
    {MIC_X, MIC_Y, "mic strip"},
    {HINT_X, HINT_Y, "hint"},
    {320, 0, "above the row"},
    {0, 32, "left of the row"},
    {628, 32, "right edge, outside"},
    {320, 56, "bottom edge, outside"},
}) do
    fired = lift(idle, point[1], point[2])
    check(fired == nil, "lift in the " .. point[3] .. " fires nothing")
    check(targets.hit(idle, point[1], point[2]) == nil, point[3] .. " contains no target")
end

fired = lift(idle, 12, 8)
check(fired == idle[1], "top-left corner of the row fires")
fired = lift(idle, 627, 55)
check(fired == idle[1], "inside the far corner of the row fires")
fired = lift(idle, 11, 8)
check(fired == nil, "one pixel left of the row misses")
fired = lift(idle, 12, 7)
check(fired == nil, "one pixel above the row misses")

fired = lift(idle, 528, 32)
check(fired == idle[1] and fired.id == "action",
    "with no game, the right end of the row is the server action")

local held = {down = false, mark = "kept"}
fired, gesture = press(idle, held, true, 320, 32)
check(held.down == false and held.mark == "kept", "step leaves the caller's gesture alone")
check(gesture.down == true and gesture ~= held, "down returns a new gesture")
fired, gesture = press(idle, {down = false}, false, 320, 32)
check(fired == nil, "a lift with no press fires nothing")
fired, gesture = press(idle, nil, "move", 320, 32)
check(fired == nil and gesture.down == false, "a move with no press does not arm")
fired, gesture = press(idle, gesture, false, 320, 32)
check(fired == nil, "a lift after a stray move fires nothing")

fired, gesture = press(idle, nil, true, CHAT_X, CHAT_Y)
fired, gesture = press(idle, gesture, false, 320, 32)
check(fired == idle[1], "a finger that lifts inside the action fires, wherever it went down")

fired, gesture = press(both, nil, true, 220, 32)
check(fired == nil, "press on the action does not fire")
fired, gesture = press(both, gesture, false, 528, 32)
check(fired == both[2], "lifting inside STOP GAME fires STOP GAME")

fired = lift(both, 220, 32)
check(fired == both[1], "lifting inside the action fires the server action while a game runs")
fired = lift(both, 427.9, 32)
check(fired == both[1], "the pixel just left of STOP GAME is the action")
fired = lift(both, 428, 32)
check(fired == both[2], "the shared edge belongs to STOP GAME")
fired = lift(both, CHAT_X, CHAT_Y)
check(fired == nil, "lifting in the chat fires nothing while a game runs")
fired = lift(both, MIC_X, MIC_Y)
check(fired == nil, "lifting on the mic strip fires nothing while a game runs")

fired = lift(stopOnly, 220, 32)
check(fired == nil, "the left of the row is not STOP GAME")
fired = lift(stopOnly, 528, 32)
check(fired == stopOnly[1], "STOP GAME fires while a game runs and the server has no action")

local before = targets.layout({action = "start"})
fired, gesture = press(before, nil, true, 528, 32)
local after = targets.layout({action = "start", game = true})
fired, gesture = press(after, gesture, false, 528, 32)
check(fired == after[2] and fired.id == "stop",
    "the targets at lift time decide, so STOP GAME can appear under a held finger")

fired, gesture = press(idle, nil, "nope", 320, 32)
check(fired == nil and gesture.down == false, "an unknown phase does not arm or fire")
fired = targets.hit(nil, 320, 32)
check(fired == nil, "hit on no list is a miss")
fired = targets.hit(idle, nil, 32)
check(fired == nil, "hit without a number is a miss")

if failures > 0 then
    io.stderr:write(string.format("targets-hit: %d failed, %d checks\n", failures, checks))
    os.exit(1)
end
print(string.format("targets-hit: %d ok", checks))
