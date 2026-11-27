-- 下屏的触摸目标。纯函数，不读 I2C，也不画。
-- 手指按下后，在目标内抬起才触发。按下和移动不触发。
-- 没有按下就抬起，不触发。抬起落在目标外，不触发。
-- STOP GAME 只在 state.game == true 时存在，贴在 server 行的右端。
-- 坐标是信息屏像素，原点左上。目标区间左闭右开：[x, x+w) × [y, y+h)。
-- 操作和 STOP GAME 相接的那条边属于 STOP GAME。

local M = {}

local ROW_X, ROW_Y, ROW_W, ROW_H = 12, 8, 616, 48
local STOP_W = 200

local ACTION_LABEL = {
    start = "START",
    restart = "RESTART",
    wizard = "WIZARD",
}

function M.layout(state)
    local source = type(state) == "table" and state or {}
    local game = source.game == true
    local op = source.action
    local label = type(op) == "string" and ACTION_LABEL[op] or nil
    local stopW = game and STOP_W or 0
    local list = {}
    if label then
        list[#list + 1] = {
            id = "action",
            op = op,
            label = label,
            x = ROW_X,
            y = ROW_Y,
            w = ROW_W - stopW,
            h = ROW_H,
        }
    end
    if game then
        list[#list + 1] = {
            id = "stop",
            op = "stop",
            label = "STOP GAME",
            x = ROW_X + ROW_W - STOP_W,
            y = ROW_Y,
            w = STOP_W,
            h = ROW_H,
        }
    end
    return list
end

function M.hit(list, x, y)
    if type(list) ~= "table" or type(x) ~= "number" or type(y) ~= "number" then
        return nil
    end
    local found
    for i = 1, #list do
        local target = list[i]
        if x >= target.x and x < target.x + target.w
            and y >= target.y and y < target.y + target.h then
            found = target
        end
    end
    return found
end

function M.step(list, gesture, phase, x, y)
    local down = type(gesture) == "table" and gesture.down == true
    if phase == true then
        return nil, {down = true}
    end
    if phase == "move" then
        return nil, {down = down}
    end
    if phase == false then
        if not down then return nil, {down = false} end
        return M.hit(list, x, y), {down = false}
    end
    return nil, {down = down}
end

return M
