# Touch

A finger down on the game screen walks the player to that point. On the title screen that same down starts the game, the same as A. The gamepad is unchanged.

## Device

`/dev/input/event1` (`gt9xx-0`, Goodix, phys `input/ts0`, by-path `platform-fe5e0000.i2c-event`).

udev marks it `ID_INPUT_TOUCHSCREEN=1`. The input properties bit is `INPUT_PROP_DIRECT`. The panel is the bottom screen, the same one as the game.

| Axis | Range |
| --- | --- |
| `ABS_X`, `ABS_MT_POSITION_X` | 0..640 |
| `ABS_Y`, `ABS_MT_POSITION_Y` | 0..480 |
| `ABS_MT_TRACKING_ID` | 0..255 |

Weston binds `event1` to output `DSI-1` and does not deliver those events to the LÖVE window, so `love.touch*` does not see a real finger. `evdev.lua` opens `event1` non-blocking and reads `struct input_event` (24 bytes on this aarch64: 16-byte timeval, then type, code, value) every frame.

`gt9xx-1` on `i2c@fe5c0000` is the other panel's controller. Its device-tree status is `disabled`, so it has no input node. `DSI-2` does not produce touch events.

## Screen

The game screen is LÖVE's main window: SDL display 0, Weston `DSI-1`, 640×480. That is the bottom screen.

The info panel is a second SDL window on display 1 (`DSI-2`). It is not touched.

## Events

`evdev.pump()` runs at the start of `love.update`. On each `SYN_REPORT`:

| Phase passed to the callback | When |
| --- | --- |
| `true`, x, y | `BTN_TOUCH` went down. One finger. |
| `"move"`, x, y | Finger still down and the point changed. |
| `false`, x, y | `BTN_TOUCH` went up. The walk target stays. |

x and y are main-window pixels, origin top-left, same space as drawing. Raw `ABS_X` / `ABS_Y` map with `(raw - min) / (max - min + 1) * 640` and the same for Y. This panel is landscape (`max X > max Y`), so the axes are not swapped.

`love.touchpressed` / `love.touchmoved` / `love.mousepressed` still call the same tap handler when a Wayland event does arrive. A second report of the same point within 80 ms and 12 px is ignored.

## What a tap does

Finger down sets a walk target, drawn as a small mint ring, and prints `evdev: down raw=(x,y) screen=(x,y)` plus `touch: walk <x>,<y>` to `/tmp/RGDS-Agents.log`.

The player moves there at `player.speed` (245 px/s). The point is clamped to the same bounds as the d-pad: x 32..608, y `PLAYER_MIN_Y`..`PLAYER_MAX_Y`. With the info panel on the other screen the play field is the whole main window (`FIELD_TOP` is 0, so `PLAYER_MIN_Y` is 46 and `PLAYER_MAX_Y` is 452). A point outside that rectangle does not set a target.

The target clears when the player is within one step or 6 px, when the shutdown dialog opens, or when the d-pad, left stick (past the 0.18 dead zone), or the arrow / WASD keys move the player. Those controls keep working and take over from the finger.

On the title screen the finger down also starts the game (`started`, start sound, BGM), the same as A or START. The shutdown dialog ignores the finger. Hold-to-talk stays on R1 (keyboard `t`).
