# RGDS device rules

You run inside `opencode serve` on an Anbernic RG DS handheld. This app is the on-device controller. The garden demo is retired.

## Hardware and runtime

- CPU is aarch64 Linux 6.1 with Buildroot glibc 2.41 and Python 3.11 at `/usr/bin/python3`.
- Two 640x480 panels. SDL display 1 is the bottom panel, the agent UI, and the LÖVE main window. SDL display 0 is the top panel: the finder, then one game. With one display, or `--one-screen`, there is no finder.
- This app runs under LÖVE 11.5 at `/mnt/mmc/Roms/APPS/RGDS-Agents/bin/love`. A user's LÖVE game uses that same binary through the start script below.

## Storage

- `/mnt/mmc/Roms/APPS/RGDS-Agents` sits on the vfat or exfat TF card. That filesystem does not store POSIX permissions. Keep app code, models, and `opencode/bin/opencode` there.
- `/userdata/opencode` sits on ext4 and supports `chmod 600`. OpenCode config, database, server password, state, and cache live there.
- Never print, copy, or commit `/userdata/opencode/server.password` or OpenCode's credential database under `/userdata/opencode/share/opencode`.

## Launching this app

- Start this app with `/mnt/mmc/Roms/APPS/RGDS-Agents/run-via-menu.sh` when `muos2.bin` is running.
- `run-via-menu.sh` sends `SIGINT` to `muos2.bin` so `dmenu_ln` runs `/tmp/.next` and releases ALSA and the gamepad.
- Never send `SIGKILL` to `muos2.bin`. That skips `/tmp/.next`.
- To relaunch this app while its `love` process is running, send `SIGTERM` to that process, wait until `muos2.bin` returns, and then run `run-via-menu.sh`. Stop a user's game with `engines/stop.sh`, not by killing this app.

## Work directory

- The work directory is the first line of `/userdata/opencode/workdir`. A missing, unreadable, or blank line means `/mnt/mmc/Roms/APPS/RGDS-Agents`.
- The finder opens there and does not show a path outside it. This app's own directory has a `main.lua` and is not a startable game.

## Starting a user's game

- One game runs at a time. The finder and your shell tool run the same scripts. There is no request file, and a user's game does not go through `/tmp/.next`.
- LÖVE: `/mnt/mmc/Roms/APPS/RGDS-Agents/engines/love/start.sh <game path>`
- OpenBOR: `/mnt/mmc/Roms/APPS/RGDS-Agents/engines/openbor/start.sh <game path>`
- Stop: `/mnt/mmc/Roms/APPS/RGDS-Agents/engines/stop.sh`
- The game path has to exist inside the work directory.
- A second start stops the game that is running and starts again. Edit the game, then run the same start script to reload it.
- `/tmp/rgds-game.pid` is three lines: the pid, the engine id (`love` or `openbor`), and the absolute game path. The log is `/tmp/rgds-game.log`.
- LÖVE: edit the Lua files and assets in the game directory. A `.love` is a zip, so unpack it to a directory and edit there.
- OpenBOR: edit the text files under `data`. Models, levels, and scripts are text in the engine's own language, not Lua. Work on the loose `data` folder. Unpack a pak with `borpak` first. The device needs `OpenBOR-arm64` installed at `engines/openbor/`; this tree does not ship it.
- Never print `OPENCODE_PASSWORD` or `/userdata/opencode/server.password`.

## Voice button

- Leave R1 free when you can. R1 is joystick button 6. It is the voice button in the finder, and the default while a game runs. Keyboard `t` is the same clip on this app.
- While a game runs, this app reads only the voice button. Every other button is the game's.
- If the game uses R1, write a one-line file with a button the game leaves free, or `none` when every button is used.
- A game directory: `rgds-voice` inside that directory.
- A `.love` or a `.pak`: `<file>.rgds-voice` beside the file.
- The line is one button number, or `none`: `1` A, `2` B, `3` Y, `4` X, `5` L1, `6` R1, `7` SELECT, `8` START, `10` L3, `11` L2, `12` R2, `13` R3.
- No file means R1. `none` turns voice off while that game runs. The user stops the game, talks with R1 in the finder, and starts it again.
- Write the file when you build or change a game. For a game you did not write, write it when the user asks.

## Touch

- Follow `TOUCH.md` for all touch work.
- The bottom panel has two touch targets. The server-row action is START, RESTART, or WIZARD. STOP GAME is shown only while a game runs and runs `engines/stop.sh`. A target acts when the finger lifts inside it.
- The top panel has no touch controller. Leave `gt9xx-1`, `muos2.bin`, and the device tree unchanged.

## OpenCode service

- Your session runs inside `opencode serve` on `127.0.0.1:4096`.
- Do not kill `opencode serve` or edit `/tmp/opencode-serve.pid`.
- Use `/mnt/mmc/Roms/APPS/RGDS-Agents/opencode/opencode-service.sh` only when the user asks to inspect or restart the service.
- That service copies this file to `/userdata/opencode/config/opencode/AGENTS.md` only when the copy is missing. A device that already has one keeps the old text until it is replaced.
