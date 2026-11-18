# Touch

A tap on the game screen walks the player to that point. The gamepad is unchanged.

## Device

`/dev/input/event1` (`gt9xx-0`, Goodix, phys `input/ts0`, by-path `platform-fe5e0000.i2c-event`).

udev marks it `ID_INPUT_TOUCHSCREEN=1`. The input properties bit is `INPUT_PROP_DIRECT`.

| Axis | Range |
| --- | --- |
| `ABS_X`, `ABS_MT_POSITION_X` | 0..640 |
| `ABS_Y`, `ABS_MT_POSITION_Y` | 0..480 |
| `ABS_MT_TRACKING_ID` | 0..255 |

Weston binds `event1` to output `DSI-1`. Nothing in udev names an output for it; `DSI-1` is the first output Weston enables.

`gt9xx-1` on `i2c@fe5c0000` is the other panel's controller. Its device-tree status is `disabled`, so it has no input node. `DSI-2` does not produce touch events.

## Screen

The game screen is LÖVE's main window: SDL display 0, Weston `DSI-1`, 640×480. That is the output the touchscreen is bound to.

The info panel is a second SDL window on display 1 (`DSI-2`). Touches are not delivered to that window. `love.touch*` only runs for the main window.

## Events

LÖVE 11, main-window pixels, origin at the top left. That is the same space the game draws in (640×480). `toGame` multiplies by `640 / windowWidth` and `480 / windowHeight` when the window is not 640×480.

| Callback | Effect |
| --- | --- |
| `love.touchpressed(id, x, y, dx, dy, pressure)` | Record the point, then handle the tap. |
| `love.touchmoved(id, x, y, dx, dy, pressure)` | Move the walk target while the finger stays inside the play field. |
| `love.touchreleased(id, x, y, dx, dy, pressure)` | Not handled. The target stays and the player finishes the walk. |
| `love.mousepressed(x, y, button)` | Recorded. Button 1 is a tap only when `love.touch.getTouches()` is empty. |

Wayland often emits touch and then a mouse event for one finger. The two are one tap when they land within 80 ms and 12 px.

## What a tap does

The tap sets a walk target, drawn as a small mint ring. The player moves there at `player.speed` (245 px/s). The point is clamped to the same bounds as the d-pad: x 32..608, y `PLAYER_MIN_Y`..`PLAYER_MAX_Y`. With the info panel on the other screen, the play field is the whole main window (`FIELD_TOP` is 0, so `PLAYER_MIN_Y` is 46 and `PLAYER_MAX_Y` is 452). A point outside that rectangle does not set a target.

The target clears when the player is within one step or 6 px, when the shutdown dialog opens, or when the d-pad, left stick (past the 0.18 dead zone), or the arrow / WASD keys move the player. Those controls keep working and take over from the tap.

On the title screen the same tap also starts the game, the same as A or START (`started`, start sound, BGM). The shutdown dialog ignores taps. Hold-to-talk stays on R1 (keyboard `t`).

Each new target prints `touch: walk <x>,<y>` to `/tmp/RGDS-Agents.log`.
