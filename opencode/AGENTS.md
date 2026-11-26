# RGDS device rules

You run inside `opencode serve` on an Anbernic RG DS handheld.

## Hardware and runtime

- CPU is aarch64 Linux 6.1 with Buildroot glibc 2.41 and Python 3.11 at `/usr/bin/python3`.
- The device has two 640x480 panels. SDL display 0 is the game panel. SDL display 1 is the info panel.
- Game code runs under LÖVE 11.5 at `/mnt/mmc/Roms/APPS/RGDS-Agents/bin/love`.

## Storage

- `/mnt/mmc/Roms/APPS/RGDS-Agents` sits on the vfat or exfat TF card. That filesystem does not store POSIX permissions. Keep app code, models, and `opencode/bin/opencode` there.
- `/userdata/opencode` sits on ext4 and supports `chmod 600`. OpenCode config, database, server password, state, and cache live there.
- Never print, copy, or commit `/userdata/opencode/server.password` or OpenCode's credential database under `/userdata/opencode/share/opencode`.

## Launching the game

- Start the app with `/mnt/mmc/Roms/APPS/RGDS-Agents/run-via-menu.sh` when `muos2.bin` is running.
- `run-via-menu.sh` sends `SIGINT` to `muos2.bin` so `dmenu_ln` runs `/tmp/.next` and releases ALSA and the gamepad.
- Never send `SIGKILL` to `muos2.bin`. That skips `/tmp/.next`.
- To relaunch while `love` is running, send `SIGTERM` to `love`, wait until `muos2.bin` returns, and then run `run-via-menu.sh`.

## Starting a user's game

- One game runs at a time. The finder and the shell tool run the same scripts. There is no request file, and a user's game does not go through `/tmp/.next`.
- LÖVE: `/mnt/mmc/Roms/APPS/RGDS-Agents/engines/love/start.sh <game path>`
- OpenBOR: `/mnt/mmc/Roms/APPS/RGDS-Agents/engines/openbor/start.sh <game path>`
- Stop: `/mnt/mmc/Roms/APPS/RGDS-Agents/engines/stop.sh`
- The game path has to exist inside the work directory. That directory is the first line of `/userdata/opencode/workdir`, or `/mnt/mmc/Roms/APPS/RGDS-Agents` when the line is missing or blank.
- A second start stops the game that is running and starts again. Edit the game's files, then run the same start script to reload it.
- `/tmp/rgds-game.pid` is three lines: the pid, the engine id (`love` or `openbor`), and the absolute game path. The log is `/tmp/rgds-game.log`.
- Never print `OPENCODE_PASSWORD` or `/userdata/opencode/server.password`.

## Touch

- Follow `TOUCH.md` for all touch work.
- Only the info panel has a live touch controller, a GT911 on `/dev/i2c-5` at address `0x14`. The game panel has no touch controller.
- Leave `gt9xx-1`, `muos2.bin`, and the device tree unchanged.

## OpenCode service

- Your session runs inside `opencode serve` on `127.0.0.1:4096`.
- Do not kill `opencode serve` or edit `/tmp/opencode-serve.pid`.
- Use `/mnt/mmc/Roms/APPS/RGDS-Agents/opencode/opencode-service.sh` only when the user asks to inspect or restart the service.
