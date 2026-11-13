-- 第二块屏上的信息面板窗口
-- RGDS 的 Weston 有两个 640x480 输出（DSI-1 / DSI-2），SDL 把它们报成 display 0 / 1。
-- LÖVE 11 每个进程只管一个窗口，这里用 LuaJIT FFI 直接调 bin/love 已链接的 libSDL2，
-- 在主窗口以外的那块屏上开一个无边框全屏 GL 窗口，并共用 LÖVE 的 GL context：
-- 面板先画进 Canvas，切到副窗口贴图 + swap，再切回主窗口交给 LÖVE 正常 present。
-- 任何一步失败都返回错误，调用方退回到把面板画在主屏上。

local ffi = require("ffi")
local bit = require("bit")

ffi.cdef[[
typedef struct SDL_Window SDL_Window;
typedef void *SDL_GLContext;
typedef struct { int x, y, w, h; } SDL_Rect;
int SDL_GetNumVideoDisplays(void);
int SDL_GetDisplayBounds(int displayIndex, SDL_Rect *rect);
void SDL_PumpEvents(void);
SDL_Window *SDL_CreateWindow(const char *title, int x, int y, int w, int h, uint32_t flags);
void SDL_DestroyWindow(SDL_Window *window);
int SDL_GetWindowDisplayIndex(SDL_Window *window);
uint32_t SDL_GetWindowID(SDL_Window *window);
SDL_GLContext SDL_GL_GetCurrentContext(void);
SDL_Window *SDL_GL_GetCurrentWindow(void);
int SDL_GL_MakeCurrent(SDL_Window *window, SDL_GLContext context);
void SDL_GL_SwapWindow(SDL_Window *window);
int SDL_GL_SetSwapInterval(int interval);
int SDL_GL_GetSwapInterval(void);
const char *SDL_GetError(void);
]]

local SDL_WINDOW_FULLSCREEN = 0x1
local SDL_WINDOW_OPENGL = 0x2
local SDL_WINDOW_BORDERLESS = 0x10
local SDL_WINDOWPOS_UNDEFINED_DISPLAY = 0x1FFF0000

local M = {canvas = nil, display = nil, mainDisplay = nil, frames = 0}

local SDL, hud, mainWin, ctx, mainSwapInterval

local function sdlError(what)
    return what .. ": " .. ffi.string(SDL.SDL_GetError())
end

local function resolveSDL()
    -- 优先用进程里已加载的那份 SDL（与 LÖVE 同一实例，窗口/GL 状态才是共享的）
    local ok = pcall(function() return ffi.C.SDL_GL_GetCurrentContext end)
    if ok then return ffi.C end
    return ffi.load("SDL2-2.0.so.0")
end

function M.open(width, height)
    local ok, lib = pcall(resolveSDL)
    if not ok then return false, "SDL2 not reachable via FFI: " .. tostring(lib) end
    SDL = lib

    local count = SDL.SDL_GetNumVideoDisplays()
    if count < 2 then return false, string.format("only %d display(s)", count) end

    mainWin = SDL.SDL_GL_GetCurrentWindow()
    ctx = SDL.SDL_GL_GetCurrentContext()
    if mainWin == nil or ctx == nil then return false, "no current GL window/context" end

    SDL.SDL_PumpEvents()
    M.mainDisplay = SDL.SDL_GetWindowDisplayIndex(mainWin)
    M.display = (M.mainDisplay == 1) and 0 or 1

    local bounds = ffi.new("SDL_Rect")
    if SDL.SDL_GetDisplayBounds(M.display, bounds) ~= 0 then return false, sdlError("GetDisplayBounds") end
    -- 共用 LÖVE 的 viewport/投影，副屏尺寸必须和主窗口一致
    if bounds.w ~= width or bounds.h ~= height then
        return false, string.format("display %d is %dx%d, expected %dx%d", M.display, bounds.w, bounds.h, width, height)
    end

    local pos = bit.bor(SDL_WINDOWPOS_UNDEFINED_DISPLAY, M.display)
    hud = SDL.SDL_CreateWindow("RGDS-Agents info", pos, pos, width, height,
        bit.bor(SDL_WINDOW_OPENGL, SDL_WINDOW_FULLSCREEN, SDL_WINDOW_BORDERLESS))
    if hud == nil then return false, sdlError("CreateWindow") end

    if SDL.SDL_GL_MakeCurrent(hud, ctx) ~= 0 then
        local err = sdlError("GL_MakeCurrent")
        SDL.SDL_GL_MakeCurrent(mainWin, ctx)
        M.close()
        return false, err
    end
    SDL.SDL_GL_MakeCurrent(mainWin, ctx)
    mainSwapInterval = SDL.SDL_GL_GetSwapInterval()

    M.canvas = love.graphics.newCanvas(width, height)
    M.windowId = SDL.SDL_GetWindowID(hud)
    return true
end

function M.isOpen()
    return hud ~= nil
end

-- 在 love.draw 里调用；drawFn 按 640x480 坐标画面板
function M.present(drawFn)
    if not hud then return end
    love.graphics.push("all")
    love.graphics.setCanvas(M.canvas)
    love.graphics.origin()
    love.graphics.clear(0, 0, 0, 1)
    drawFn()
    love.graphics.setCanvas()
    love.graphics.pop()
    love.graphics.flushBatch()

    SDL.SDL_GL_MakeCurrent(hud, ctx)
    love.graphics.push("all")
    love.graphics.origin()
    love.graphics.clear(0, 0, 0, 1)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setBlendMode("replace")
    love.graphics.draw(M.canvas, 0, 0)
    love.graphics.pop()
    love.graphics.flushBatch()
    -- SDL 的 Wayland 后端只有一个进程级 swap interval，并在 SwapWindow 时自己等 frame callback。
    -- 主窗口已经按 vsync 等过一次，副窗口再等会让帧率减半，所以只在副窗口 swap 期间临时设 0。
    SDL.SDL_GL_SetSwapInterval(0)
    SDL.SDL_GL_SwapWindow(hud)
    SDL.SDL_GL_SetSwapInterval(mainSwapInterval)
    SDL.SDL_GL_MakeCurrent(mainWin, ctx)
    M.frames = M.frames + 1
end

function M.close()
    if hud then
        SDL.SDL_DestroyWindow(hud)
        hud = nil
    end
end

return M
