function love.conf(t)
    t.identity = "RGDS-Agents"  -- 存档目录与原版 rgds-lua-demo 分开
    t.version = "11.3"              -- 掌机自带 LÖVE 11.5，写 11.3 兼容更旧的构建
    t.window.title = "RGDS-Agents"
    t.window.width = 640            -- RGDS 原生分辨率（DSI-1 / DSI-2 均为 640x480）
    t.window.height = 480
    t.window.fullscreen = false     -- Mac 窗口运行；掌机端由启动脚本决定是否全屏
    t.window.fullscreentype = "desktop"
    t.window.resizable = false
    t.window.vsync = 1
    t.window.highdpi = false
    t.window.borderless = false
    t.audio.enabled = true          -- 从掌机菜单运行时出声；设备被占用时 pcall 降级
    t.modules.physics = false
    t.modules.video = false

    for _, value in ipairs(arg or {}) do
        if value == "--fullscreen" then
            t.window.fullscreen = true
            t.window.borderless = true
        elseif value == "--headless" then
            -- 自检/输入日志模式不弹窗，避免抢前台
            t.window.visible = false
        end
    end
end
