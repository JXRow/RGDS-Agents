# RGDS-Agents

On-device controller for the Anbernic RG DS. The garden demo is retired. The field, the title card, the score, and the status block are gone with it.

The app does two jobs:

1. It keeps the OpenCode server configured and running. The bottom panel is the agent's UI.
2. It runs games for the engines in `engines.lua`. Today those engines are LÖVE and OpenBOR. The agent can start a game on the top panel and edit that game's files.

## Screens

Startup takes the top display, the gamepad (`event3`), and ALSA from the stock muOS menu. The menu exits, and the top panel belongs to the finder. `run-via-menu.sh` writes `/tmp/.next`, runs `/mnt/vendor/ctrl/cpu_setting.sh deflt`, and sends `SIGINT` to `muos2.bin`. `SIGKILL` skips `/tmp/.next`. The script refuses to start when the menu is not running.

| Panel | SDL display | What is on it | Touch |
| --- | --- | --- | --- |
| Bottom | 1 | Agent UI. This is the LÖVE main window. | GT911, 640×480, origin top-left |
| Top | 0 | The finder, then the game | none |

`screens.lua` puts the main window on SDL display 1 when two displays are present, including `--one-screen`. `--one-screen` only skips the finder window. LÖVE's display number is the SDL index plus one. `subscreen.lua` opens the finder on the other display. With one display, the agent UI is the only window and there is no finder.

A live pid in `/tmp/rgds-game.pid` closes the finder window. The app reads that file every 0.25 s. When the pid is gone, the finder opens again on the same selection. Whether Weston then gives the top output to the game's own window still needs a device.

## Bottom panel

The server row is one state word, one detail line, and one action, and this tree draws it. The action labels START, RESTART, and WIZARD, and the STOP GAME rectangle, are in `targets.lua`. The words come from `opencode/opencode-service.sh status`, the adapter events, `/tmp/opencode-setup.json`, and the `model` key in `/userdata/opencode/config/opencode/opencode.json`. The status script runs again every 5 seconds while the state is not Running, and every 15 seconds while it is.

| State | When | Action |
| --- | --- | --- |
| Not configured | `opencode.json` is missing or has no `model`. A valid setup file shows its token and URL and clears the action. | WIZARD, while no setup token is showing |
| Starting | `start` has not returned, health has been `unhealthy` for under 15 seconds, or the adapter has not said `net: ok`. Chat is held. | none |
| Running | Status exits 0 with `health: ok`, and the adapter says `net: ok`. The detail is the server version. | RESTART |
| Failed | Status is `stopped`, `start` exits 1, health stays unhealthy for 15 seconds, or the adapter reports `offline`, `server`, or `helper`. The log is `/tmp/opencode-serve.log`. | START |
| Auth problem | The adapter reports `auth`. An unreadable password file, or `HTTP 401` / `HTTP 403` from the local server, is the password case. Any other auth message is the provider key. | RESTART for the password, WIZARD for the key while no setup token is showing |

The chat log tags a row YOU, a language code, PC, or AI. A PC row is a `remote_user` turn. A tool line is gold, `name: title` or the tool name. The setup token and URL stay on the first chat row while `/tmp/opencode-setup.json` is valid. The mic strip sits under the chat. Hold R1, or press `t`, for one voice clip.

Touch targets are in [TOUCH.md](TOUCH.md). The server-row action is START, RESTART, or WIZARD. STOP GAME is shown only while a game runs, and it runs `engines/stop.sh`.

## Finder

The finder opens at the work directory. It lists `..` when the path is under that root, then directories, then files, each in byte order. A game row carries its engine label. A plain directory has a trailing slash. A file that is not a game is dim. The kind line is the engine label, `folder`, `not a game`, `empty`, or the install hint for a missing binary.

The pad, once the menu has exited:

- Up and down move the selection and stop at the ends.
- Left and B go to the parent. At the root, B does nothing.
- Right and A enter a folder. A on a startable game runs that engine's start script. A on any other file does nothing.
- R1 is the voice clip. It is not a finder key. A finger does not move the selection.

This app's own directory has a `main.lua` and is still only a folder.

While a game runs, the bottom hint names the engine, the game, and the voice button, and STOP GAME is shown. If the start script exits 1, the finder stays (or reopens if the engine exited during the startup watch) and the bottom hint is pink with the script's last line, cut at 180 bytes and clipped to fit the row.

## Work directory

One directory. It is the first line of `/userdata/opencode/workdir`. A missing, unreadable, or blank line means `/mnt/mmc/Roms/APPS/RGDS-Agents`. `opencode/opencode-service.sh`, `rgds-aid.py`, and `finder.lua` read that file. The finder does not show a path outside it.

## Engines

An engine is one entry in `engines.lua`. The finder asks that table which rows are games. Entries are asked in list order and the first match wins. One game runs at a time.

| Field | Meaning |
| --- | --- |
| `id`, `label` | Short name, and the tag on a finder row |
| `binary` | Absolute path. A missing binary keeps the tag and is not startable. The kind line names what to install. |
| `detect` | Whether this file or directory is a game |
| `start` | `engines/<id>/start.sh`, one argument, the game path |
| `stop` | `SIGTERM`, then `SIGKILL` after 2 seconds. Both engines use `engines/stop.sh`. |
| `edits` | What the agent changes. Text for the agent. |

LÖVE recognises a directory with a top-level file `main.lua`, or a `.love` whose zip root contains `main.lua`. The zip check reads the central directory and does not unpack. `conf.lua` alone is not a game. The `.love` suffix matches any case. It starts with this app's `bin/love`. The agent edits the Lua files and assets in the game directory. A `.love` is unpacked to a directory first.

OpenBOR recognises a file whose name ends in `.pak` in any case, except `menu.pak` in any case, or a directory with a top-level `data` directory in any case. It starts with `engines/openbor/OpenBOR-arm64`, and that directory is the library path. This tree ships no OpenBOR binary, no pak, and no `borpak`. Install `OpenBOR-arm64` and its libraries at `engines/openbor/` on the device. The agent edits the text files under `data`. A pak is unpacked with `borpak` first. Which display OpenBOR opens on, and a loose `data` start, still need a device. The start script still passes that directory as its one argument.

A further engine is another entry in the table, plus `engines/<id>/start.sh`. Put it before or after the others on purpose, because the first match wins.

## Starting and stopping a game

The finder and the agent's shell tool run the same script. A user's game is launched by that script, not by `/tmp/.next`.

- LÖVE: `engines/love/start.sh <game path>`
- OpenBOR: `engines/openbor/start.sh <game path>`
- Stop: `engines/stop.sh`

On the device those paths sit under `/mnt/mmc/Roms/APPS/RGDS-Agents/`.

The start script refuses a path that is missing, outside the work directory, or this app's own directory. If `/tmp/rgds-game.pid` names a live game, it stops that game first, so a second start is the reload after an edit. It clears `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME`, and `OPENCODE_PASSWORD` before the engine runs, then starts the engine in the background, ignoring `HUP`, and returns. The pid file is three lines: the pid, the engine id (`love` or `openbor`), and the absolute game path. The log is `/tmp/rgds-game.log`. `engines/stop.sh` sends `SIGTERM`, then `SIGKILL` after 2 seconds, and removes the pid file. The scripts do not print the server password.

The agent edits the game with its own tools, then runs the same start script to reload. LÖVE's launcher exports are `LD_LIBRARY_PATH`, `ALSOFT_CONF`, and `SDL_VIDEO_DOUBLE_BUFFER`, and they are for `bin/love` only. The OpenBOR script uses `engines/openbor/` as its library path and unsets those two LÖVE variables.

## Voice button

Voice stays on a gamepad button. The default is R1, joystick button 6, in the finder and during a game. Keyboard `t` is the same clip. While a game runs, this app reads only the voice button. Every other button is the game's.

A game that needs R1 has a one-line file. Inside a game directory the name is `rgds-voice`. Beside a `.love` or a `.pak` the name is `<file>.rgds-voice`. The line is a button number in this app's numbering, or `none`:

`1` A, `2` B, `3` Y, `4` X, `5` L1, `6` R1, `7` SELECT, `8` START, `10` L3, `11` L2, `12` R2, `13` R3.

No file means R1. `none` turns voice off while that game runs. The user taps STOP GAME, talks with R1 in the finder, and starts the game again. The agent writes the file when it builds or changes a game, and leaves R1 free when it can. When wired into `main.lua`, the bottom hint names the button, for example `HOLD L2 TALK`, or `VOICE OFF`.

`voicebutton.lua` is in the tree, but `main.lua` does not load it yet. Until that wiring lands, the running hint stays `HOLD R1 TALK` from `gamepid.lua`.

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

To relaunch this app while its `love` process is in front, `SIGTERM` that process and wait until `muos2.bin` is back, then run the script again. A user's game is stopped with `engines/stop.sh`, not by killing this app. The app log is `/tmp/RGDS-Agents.log`.

## OpenCode

OpenCode v2 (`opencode serve`) runs on the RGDS at `127.0.0.1:4096`. Config, the local server password, and the SQLite credential database live on ext4 under `/userdata/opencode` with mode `600`. Do not print the password file or the credential database.

1. Download the pinned aarch64 OpenCode v2 binary on your dev machine:

```sh
./setup-opencode.sh
```

2. Deploy the binary, service scripts, and `/etc/init.d/S55opencode` to the device:

```sh
./deploy.sh root@rgds.local
```

3. Start the temporary web setup wizard on the device to write `/userdata/opencode/config/opencode/opencode.json`, restart `opencode serve`, and store your provider API key via OpenCode's `/api/credential` endpoint:

```sh
ssh -o IdentitiesOnly=yes -o IdentityFile=~/.ssh/id_ed25519 root@rgds.local \
  /mnt/mmc/Roms/APPS/RGDS-Agents/opencode/opencode-setup-web.py
```

Open the printed LAN URL on your phone or PC, enter the 6-character pairing code, and submit your provider and API key. The wizard restarts `opencode serve`, verifies `/api/info`, stores the credential, and closes port 8787.

4. Connect your PC terminal (`opencode --server`) to the device daemon over an SSH loopback tunnel:

```sh
./opencode/attach-rgds.sh
```

Pass a custom SSH target as the first argument, or set `RGDS_SSH_KEY`, `RGDS_OPENCODE_PORT`, `RGDS_OPENCODE_DATA_ROOT`, or `RGDS_LOCAL_PORT`.

On start, `opencode/opencode-service.sh` copies `opencode/AGENTS.md` to `/userdata/opencode/config/opencode/AGENTS.md` only when that copy is missing. A device that already has the file keeps the old copy until someone replaces it.

## Checks

These ran on a dev machine with `lua5.1` and `sh`. No SSH, no SDL window, no port 4096, and no port 7788:

- `tests/screens-plan.lua` — one display, two displays, `--one-screen`
- `tests/finder-test.lua` — work directory, order, staying inside the root, this app's directory
- `tests/engines-table.lua` — LÖVE and OpenBOR fixtures, including a `.love` with and without a root `main.lua`, and `menu.pak`
- `tests/targets-hit.lua` — lift inside a target, lift outside, STOP GAME only while a game runs
- `tests/gamepid-test.lua` — live pid, dead pid, missing file, pad, STOP GAME
- `tests/game-start-stop.sh` — a path outside the work directory is refused, the pid file is written, a second start stops the first, and the service's `XDG_*` values do not reach the stand-in engine

Also on this tree: `tests/serverstate-harness.lua`, `tests/server-wire.lua`, and `tests/voicebutton-harness.lua`. `main.lua` draws the server row, does not draw the finger mark, and does not log `touch: info`. `voicebutton.lua` is in the tree and is not loaded by `main.lua` yet. STOP GAME is wired.

These still need a device:

1. After the finder window closes, Weston giving the top output to the game.
2. A game opening ALSA playback while this app holds an OpenAL device.
3. This app still receiving the voice button while a game has the pad. Both can read `event3`. This app's launcher does not set `SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS`.
4. A game started from the agent's shell tool still running after that call returns, and after a server restart. The start script ignores `HUP` and does not call `setsid`.
5. OpenBOR: an arm64 binary and its libraries on the device, which display it opens on, and a loose `data` directory start.
6. Replacing `/userdata/opencode/config/opencode/AGENTS.md` on a device that already has one. The service copies the file only when the destination is missing.
