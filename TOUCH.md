# Touch

A finger on the info screen draws a cross at that point. The gamepad is unchanged. A finger does not move the player and does not start the game.

## Device

`/dev/input/event1` (`gt9xx-0`, Goodix, phys `input/ts0`, by-path `platform-fe5e0000.i2c-event`).

udev marks it `ID_INPUT_TOUCHSCREEN=1`. The input properties bit is `INPUT_PROP_DIRECT`. This is the info screen.

| Axis | Range |
| --- | --- |
| `ABS_X`, `ABS_MT_POSITION_X` | 0..640 |
| `ABS_Y`, `ABS_MT_POSITION_Y` | 0..480 |
| `ABS_MT_TRACKING_ID` | 0..255 |

Weston does not deliver these events to the LÖVE window. `evdev.lua` opens `event1` non-blocking and reads `struct input_event` (24 bytes on this aarch64: 16-byte timeval, then type, code, value) every frame.

`gt9xx-1` on `i2c@fe5c0000` is disabled in the device tree and has no input node. Do not enable it.

## Screen

The mark is drawn on the info panel. That window is SDL display 1, 640×480, the panel `gt9xx-0` is on. The game window is SDL display 0 and does not receive this finger.

## Events

`evdev.pump()` runs at the start of `love.update`. On each `SYN_REPORT` it calls `noteFinger(phase, x, y)`:

| Phase | When |
| --- | --- |
| `true` | Finger down: `BTN_TOUCH`, an active tracking id, or an `ABS` position in the report. |
| `"move"` | Finger still down and the point changed. |
| `false` | Finger up. The cross stays where the finger left. |

x and y are info-panel pixels, origin top-left. Raw `ABS_X` / `ABS_Y` map with `(raw - min) / (max - min + 1) * 640` and the same for Y. This panel is landscape (`max X > max Y`), so the axes are not swapped.

## What a finger does

While the finger is down the info screen draws a gold ring, a gold cross (112 px across), a pink dot, and the label `TOUCH x, y`. After the finger lifts, the same mark stays and turns mint.

Finger down prints one line to `/tmp/RGDS-Agents.log`:

```
touch: info <x>,<y>
```

Moves do not print. The d-pad, stick, and face buttons are unchanged.
