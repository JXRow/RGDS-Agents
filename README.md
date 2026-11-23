# RGDS-Agents

LÖVE game for the Anbernic RG DS. Speech is a small `sv-helper` process (sherpa-onnx SenseVoice) beside the game. Chat goes through `rgds-aid.py`, which talks to on-device `opencode serve`.

## Setup

The model, sherpa libraries, and `stt/sv-helper` are not in git. From the repo root:

```sh
./setup-stt.sh
```

That downloads SenseVoice-Small int8 `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17` (model md5 `0e8e550411d3589be9f0af06f1c8fec3`), the sherpa-onnx v2.0.1 aarch64 shared libraries, and builds `stt/sv-helper`.

On an x86_64 dev machine you need `aarch64-linux-gnu-gcc` (Fedora also needs `sysroot-aarch64-fc*-glibc`; Debian/Ubuntu needs `libc6-dev-arm64-cross`). On the device the script uses the native `gcc`.

The device needs LÖVE 11.5 at `/opt/love/love-11.5`. `deploy.sh` copies that into the app and stops with install commands if it is missing.

```sh
./deploy.sh rgds
```

`rgds` is the SSH host (`rgds.local`). That copies the app to `/mnt/mmc/Roms/APPS/RGDS-Agents/` and writes the menu entry `/mnt/mmc/Roms/APPS/RGDS-Agents.sh`.

Launch it from the device APPS menu. With the menu already up (`muos2.bin` running):

```sh
ssh rgds /mnt/mmc/Roms/APPS/RGDS-Agents/run-via-menu.sh
```

That script sends `SIGINT` to `muos2.bin`. The menu exits 0, `dmenu_ln` runs `/tmp/.next`, and the menu releases ALSA and the gamepad. `SIGKILL` on `muos2.bin` skips `/tmp/.next`.

To relaunch while the game is in front, `SIGTERM` its `love` process and wait until `muos2.bin` is back, then run the script again. The script refuses to start when the menu is not running. The game log is `/tmp/RGDS-Agents.log`.
