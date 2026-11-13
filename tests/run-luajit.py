#!/usr/bin/env python3
"""Run a Lua file (or syntax-check files) with the game's bundled LuaJIT, without starting LÖVE.

  python3 run-luajit.py check a.lua b.lua ...    # LuaJIT parse only
  python3 run-luajit.py run script.lua           # run; script reads its settings from env
"""
import ctypes
import os
import sys

LIB = os.environ.get("LUAJIT_LIB", "/mnt/mmc/Roms/APPS/rgds-lua-demo-v2/lib/libluajit-5.1.so.2")
lj = ctypes.CDLL(LIB, mode=ctypes.RTLD_GLOBAL)
lj.luaL_newstate.restype = ctypes.c_void_p
lj.luaL_openlibs.argtypes = [ctypes.c_void_p]
lj.luaL_loadfile.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
lj.lua_pcall.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int]
lj.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
lj.lua_tolstring.restype = ctypes.c_char_p


def new_state():
    st = lj.luaL_newstate()
    lj.luaL_openlibs(st)
    return st


def main():
    mode, files = sys.argv[1], sys.argv[2:]
    rc = 0
    for path in files:
        st = new_state()
        err = lj.luaL_loadfile(st, path.encode())
        if err == 0 and mode == "run":
            err = lj.lua_pcall(st, 0, 0, 0)
        if err:
            print("FAIL %s: %s" % (path, lj.lua_tolstring(st, -1, None).decode()))
            rc = 1
        elif mode == "check":
            print("ok %s" % path)
    sys.stdout.flush()
    return rc


if __name__ == "__main__":
    sys.exit(main())
