-- 主窗口放哪块屏。纯函数：不读设备、不打开窗口。
-- 两块及以上屏，且不是 --one-screen：主窗口在 SDL display 1（下屏），
-- LÖVE 的 display 编号是 SDL 编号加一；第二个窗口在 SDL display 0（上屏）。
-- 一块屏、数量未知，或 oneScreen：只有主窗口，在 SDL display 0。

local M = {}

function M.plan(displayCount, oneScreen)
    local split = (not oneScreen) and type(displayCount) == "number" and displayCount >= 2
    if split then
        return {
            agentsSdl = 1,
            secondSdl = 0,
            loveDisplay = 2,
            openSecondWindow = true,
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
