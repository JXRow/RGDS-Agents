-- 主窗口放哪块屏。纯函数：不读设备、不打开窗口。
-- 两块及以上屏：主窗口在 SDL display 1（下屏，有触摸）。
-- LÖVE 的 display 编号是 SDL 编号加一。第二个窗口在 SDL display 0（上屏）。
-- --one-screen 只是不开第二个窗口，主窗口仍在下屏。
-- 一块屏或数量未知：只有主窗口，在 SDL display 0。

local M = {}

function M.plan(displayCount, oneScreen)
    local count = type(displayCount) == "number" and displayCount or 0
    if count >= 2 then
        return {
            agentsSdl = 1,
            secondSdl = not oneScreen and 0 or nil,
            loveDisplay = 2,
            openSecondWindow = not oneScreen,
        }
    end
    return {
        agentsSdl = 0,
        secondSdl = nil,
        loveDisplay = 1,
        openSecondWindow = false,
    }
end

return M
