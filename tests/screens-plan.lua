-- screens.plan：一块屏、两块屏、--one-screen。不需要掌机，也不开窗口。
local script = arg[0]
local slash = script:match("^.*()/")
local root = slash and (script:sub(1, slash) .. "..") or ".."
package.path = root .. "/?.lua;" .. package.path

local screens = require("screens")

local function check(count, oneScreen, agentsSdl, secondSdl, loveDisplay, openSecondWindow)
    local plan = screens.plan(count, oneScreen)
    local label = tostring(count) .. (oneScreen and " --one-screen" or "")
    local function eq(got, want, field)
        if got ~= want then
            io.stderr:write(string.format(
                "count %s %s: got %s want %s\n",
                label, field, tostring(got), tostring(want)))
            os.exit(1)
        end
    end
    eq(plan.agentsSdl, agentsSdl, "agentsSdl")
    eq(plan.secondSdl, secondSdl, "secondSdl")
    eq(plan.loveDisplay, loveDisplay, "loveDisplay")
    eq(plan.openSecondWindow, openSecondWindow, "openSecondWindow")
end

check(0, nil, 0, nil, 1, false)
check(1, nil, 0, nil, 1, false)
check(nil, nil, 0, nil, 1, false)
check(2, nil, 1, 0, 2, true)
check(4, nil, 1, 0, 2, true)
check(2, true, 0, nil, 1, false)
check(4, true, 0, nil, 1, false)
check(1, true, 0, nil, 1, false)

print("screens plan ok")
os.exit(0)
