# Charge Keeper

A menu-bar app that stops a MacBook charging at a level you choose, using the Mac's own built-in charge limit
(the private PowerUI framework). No charging-chip key is written, no password, no background helper.

Author: John Hesch. Original code. Apple silicon, personal use.

## Safety

The limit is always put back: on Quit and on every catchable signal; a small watchdog (a second copy of the program)
covers a crash or kill -9; at start-up a leftover note from an earlier run triggers a clean-up. A limit the app did
not set (for example Apple's own) is never touched.

## Flags

`--restore` puts the limit back to off / 100. `--probe` reads only. `--selftest` runs the logic checks. `--render <folder>` draws the panel and icon to PNG files off-screen (no window).

## Building

Cloud: `scripts/cloud-build.sh` (GitHub Actions, manual trigger only). Local, niced, one job: `scripts/local-build.sh`.
Both produce `Charge Keeper.app`, signed ad hoc. Neither installs or launches it.

Install (own Mac): `scripts/install.sh` copies the build into /Applications and opens it. From /Applications the app
adds itself to Login Items once, so it starts with the Mac and cleans up any limit left by a crash or power cut.
