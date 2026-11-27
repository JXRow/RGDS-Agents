# Touch

A finger on the bottom panel hits a touch target when it lifts inside that target. Press and move do not fire a target. A lift outside every target does nothing. The finger does not move the finder selection and does not start a game.

The top panel has no touch controller. Test on the bottom panel.

## Panels

| Panel | SDL display | Window | Touch |
| --- | --- | --- | --- |
| Bottom, agent UI | 1 | LÖVE main window | GT911, 640×480 |
| Top, finder then the game | 0 | `subscreen.lua`, then the game process | none |

With one display, the agent UI is the only window. With two displays, `--one-screen` keeps that window on SDL display 1 and does not open the finder. See `screens.lua`.

`gt9xx-0` is on I2C bus 5 (`fe5e0000.i2c`), address `0x14`, input node `/dev/input/event1` (phys `input/ts0`, by-path `platform-fe5e0000.i2c-event`). udev marks it `ID_INPUT_TOUCHSCREEN=1` with `INPUT_PROP_DIRECT`. The GPIO IRQ is `rockchip_gpio_irq 14` (`gt9xx` in `/proc/interrupts`). A rising count means the bottom panel was touched.

`gt9xx-1` on `i2c@fe5c0000` is `status = "disabled"` in the device tree and has no input node. Leave it disabled. Binding it from sysfs fails (`no device tree`), and the kernel has no overlay support. Leave `muos2.bin` and the device tree as they are.

## Targets

Coordinates are bottom-panel pixels, origin top-left. A target is the half-open rectangle `[x, x+w) × [y, y+h)`. The layout is `targets.lua`.

The server row is `x=12`, `y=8`, `616×48`.

- The action fills that row. Its label is START, RESTART, or WIZARD, from the server state in [README.md](README.md). While STOP GAME is also shown, the action is the left part of the row and STOP GAME is the right `200×48`. The shared edge belongs to STOP GAME.
- STOP GAME exists only while a game is running. It runs `engines/stop.sh`.

The chat log, the tool line, and the mic strip are not targets.

`targets.step` fires the target that contains the lift. A finger that was not tracked down does not fire a target on the way up.

## Where the coordinates come from

Weston holds `event1` and does not send Wayland touch to either LÖVE window. `love.touchpressed` and `SDL_FINGERDOWN` / `SDL_FINGERUP` / `SDL_FINGERMOTION` (`0x700`–`0x702`) do not fire for this panel.

The goodix driver counts the IRQ and does not queue `input_event`s on `event1`. A non-blocking read returns `EAGAIN` after `EVIOCGRAB` (`0x40044590`) as well. `evdev.lua` still opens and grabs `event1`. The point that hits a target comes from the I2C registers, through `touchthread.lua` and `touchpoll.lua`.

The chip answers as a GT911: register `0x8140` reads `911`. Config at `0x8047` is version, then little-endian x max, y max. On this panel that is 640×480.

Finger data is register `0x814E`, 16-bit address, big-endian on the wire:

| Byte | Meaning |
| --- | --- |
| 0 | Bit 7 set means the buffer is ready. The low nibble is the finger count. |
| 1 | Track id |
| 2–3 | x, little-endian |
| 4–5 | y, little-endian |

After a ready buffer, write `0` to `0x814E`. The chip keeps the same point until that write. Open `/dev/i2c-5` and use `I2C_RDWR` (`0x0707`): one write of the 16-bit register, then a read. Address `0x14`.

x and y are bottom-panel pixels, origin top-left. Scale with `640 / xmax` and `480 / ymax` from the config.

## Events

`touchthread.lua` polls the register. A LÖVE thread does not load `love.timer` until the file requires it; without that require the thread exits on the first sleep. Idle poll is 8 ms. While a finger is down the poll is 2 ms. The thread pushes a point only when the position changes, and pushes the release when the buffer is clear.

`touchpoll.pump()` drains channel `rgds-touch`. That callback is `onPanelFinger`: STOP GAME for a running game, then the server-row action. `noteFinger` still runs `gamepid.finger` for evdev, SDL, and the mouse, so those paths can fire STOP GAME. They do not log `touch: info`. Bottom-panel targets take the `touchpoll` point.

| Phase | When |
| --- | --- |
| `true` | The finger count goes from 0 to at least 1. The gesture is remembered. Nothing fires. |
| `"move"` | The finger stays down and the point changed. Nothing fires. |
| `false` | The buffer is clear, or the count is 0. The target under the lift fires. |

`pump` runs at the start of `love.update`.

## The finger mark

The ring, the cross, the `TOUCH x, y` label, and the `touch: info` log are gone from `main.lua`. A working start still prints `touchpoll: gt911 640x480`.
