# Agents

Touch, the bottom panel, or the GT911: follow [TOUCH.md](TOUCH.md). The top panel does not receive a finger.

Deploy, relaunch, sound, and the gamepad: follow [README.md](README.md) Setup and the header of `run-via-menu.sh`.

`ssh rgds` fails with "Too many authentication failures" when the client offers every key. Connect as `root@rgds.local` with `IdentitiesOnly=yes` and `IdentityFile=~/.ssh/id_ed25519`.
