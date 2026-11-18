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

The chip answers on I2C bus 5, address `0x14`, as a GT911 (`0x8140` reads `911`). Its output size in config `0x8047` is 640×480. Finger data is register `0x814E`: bit 7 means the buffer is ready, the low nibble is the finger count, then track id, x, y (little-endian). `touchpoll.lua` reads that every frame and writes `0` back to `0x814E`. `event1` is still opened and grabbed, but this kernel driver does not queue input events there, so the mark follows the I2C coordinates.

`gt9xx-1` on `i2c@fe5c0000` is disabled in the device tree and has no input node. Do not enable it.

## Screen

The mark is drawn on the info panel. That window is SDL display 1, 640×480, the panel `gt9xx-0` is on. The game window is SDL display 0 and does not receive this finger.

## Events

`touchpoll.pump()` runs at the start of `love.update`. When `0x814E` bit 7 is set and the finger count is at least 1, it calls `noteFinger`:

| Phase | When |
| --- | --- |
| `true` | The finger count goes from 0 to at least 1. |
| `"move"` | The finger stays down. |
| `false` | Bit 7 is clear again, or the count is 0. The cross stays. |

x and y are info-panel pixels, origin top-left. The chip's x and y are scaled by `640 / xmax` and `480 / ymax` from the config (both 640 and 480 on this panel).

## What a finger does

While the finger is down the info screen draws a gold ring, a gold cross (112 px across), a pink dot, and the label `TOUCH x, y`. After the finger lifts, the same mark stays and turns mint.

Finger down prints one line to `/tmp/RGDS-Agents.log`:

```
touch: info <x>,<y>
```

Moves do not print. The d-pad, stick, and face buttons are unchanged.
