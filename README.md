# Pocket Garden

LÖVE game for the Anbernic RG DS. The app is `rgds-lua-app-v2`. Speech is a small `sv-helper` process (sherpa-onnx SenseVoice) beside the game. Chat goes through `rgds-aid.py` to MiniMax. The API key stays on the device.

## Fresh checkout

The model, sherpa libraries, and `stt/sv-helper` are not in git. From `rgds-lua-app-v2`:

```sh
./setup-stt.sh
```

That downloads SenseVoice-Small int8 `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17` (model md5 `0e8e550411d3589be9f0af06f1c8fec3`), the sherpa-onnx v2.0.1 aarch64 shared libraries the helper was linked against, and builds `stt/sv-helper`. It does not use the 2025-09-09 Cantonese fine-tune.

On an x86_64 dev machine you need `aarch64-linux-gnu-gcc` (Fedora also needs `sysroot-aarch64-fc*-glibc`; Debian/Ubuntu needs `libc6-dev-arm64-cross`). On the device the script uses the native `gcc`.

The device needs LÖVE 11.5 at `/opt/love/love-11.5`. `deploy.sh` copies that into the app and stops with install commands if it is missing.

```sh
./deploy.sh rgds
```

`rgds` is the SSH host (`rgds.local`). That copies the app to `/mnt/mmc/Roms/APPS/rgds-lua-demo-v2/` and writes the menu entry `/mnt/mmc/Roms/APPS/rgds-lua-demo-v2.sh`.

Launch it from the device APPS menu. With the menu already up:

```sh
ssh rgds /mnt/mmc/Roms/APPS/rgds-lua-demo-v2/run-via-menu.sh
```

Do not SSH the menu script itself. The menu still holds the audio device and the gamepad.

For chat, on the device create `/userdata/rgds-ai/config.json` and `chmod 600`. `setup-stt.sh` prints the shape. Put your own key there. Do not commit it.

## Left out of git

`minimax.key` and any `config.json` with an API key, `stt/model.int8.onnx`, `stt/lib/*.so`, `stt/sv-helper`, downloaded archives under `.cache/`, and the dated `rgds-lua-app-v2-backup-*` trees.
