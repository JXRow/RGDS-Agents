# Pocket Garden

LÖVE game for the Anbernic RG DS. The app is `rgds-lua-app-v2`. Speech is a small `sv-helper` process (sherpa-onnx SenseVoice) beside the game. Chat goes through `rgds-aid.py`, which calls an OpenAI-compatible chat endpoint. The API key stays on the device.

## Fresh checkout

The model, sherpa libraries, and `stt/sv-helper` are not in git. From `rgds-lua-app-v2`:

```sh
./setup-stt.sh
```

That downloads SenseVoice-Small int8 `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17` (model md5 `0e8e550411d3589be9f0af06f1c8fec3`), the sherpa-onnx v2.0.1 aarch64 shared libraries, and builds `stt/sv-helper`.

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

## API key

`rgds-aid.py` reads `$RGDS_AI_CONFIG` if that variable is set. Otherwise it uses the first file that exists: `/userdata/rgds-ai/config.json`, then `/root/.config/rgds-ai/config.json`. If neither exists, it still tries `/userdata/rgds-ai/config.json`.

Create that file on the device and `chmod 600` it. The program does not set the mode itself. Do not commit the file, and do not commit `minimax.key`.

`$RGDS_AI_KEY`, if set, replaces `api_key` after the file is loaded. The file is still required.

MiniMax, using the built-in URL and model:

```json
{"provider":"minimax","api_key":"PASTE_YOUR_KEY"}
```

`provider` `minimax` fills in `base_url` `https://api.minimax.cn/v1` and `model` `MiniMax-M3` when those fields are omitted.

DeepSeek, or any other OpenAI-compatible API, is the same file with your own `base_url` and `model`. The provider name is not checked except for that MiniMax default. The sidecar POSTs `{base_url}/chat/completions` with `Authorization: Bearer`, `stream: true`, and `max_completion_tokens` (the config field is `max_tokens`, default 800). For `MiniMax-M3` it also sends `thinking: {type: "disabled"}` unless `thinking` is `disabled` or `adaptive`.

```json
{"provider":"deepseek","api_key":"PASTE_YOUR_KEY","base_url":"https://api.deepseek.com","model":"deepseek-chat"}
```

Optional fields: `system`, `max_tokens`, `history_turns` (default 6). Chat fails closed unless `api_key`, `base_url`, and `model` are all set.

## Left out of git

`minimax.key` and any `config.json` with an API key, `stt/model.int8.onnx`, `stt/lib/*.so`, `stt/sv-helper`, and downloaded archives under `.cache/`.
