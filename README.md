# Charge Keeper

A menu-bar app that stops a MacBook charging at a level you choose. From 80 to 100 it uses the Mac's own built-in charge
limit (the private PowerUI framework), which needs no password. Under 80 (macOS refuses its own limit there) a small helper,
installed once with the Mac password (`scripts/install-helper.sh`), switches the charger's power off at the limit and back on
5 points lower (SMC key CHIE); the Mac's own limit stays at 80 as a backstop. Without the helper, under 80 holds at 80.

Author: John Hesch. Original code. Apple silicon, personal use.

## Safety

The limit is always put back: on Quit and on every catchable signal; a small watchdog (a second copy of the program)
covers a crash or kill -9; at start-up a leftover note from an earlier run triggers a clean-up. A limit the app did
not set (for example Apple's own) is never touched.

The charger helper puts power back on when the app's connection closes (quit, crash, force-quit), when the app stops
checking in, before sleep, when it starts (boot, or after it died; launchd restarts it), on a stop signal, at a 40% floor,
and from a dead-man thread. It never touches a cut it did not make, and Charge Keeper does not switch the charger while
AlDente runs or while the lid is closed. `--helper-fake <folder>` runs the real helper on a file instead of the chip, for tests.

## Flags

`--helper <uid>` is the charger helper (root, started by launchd). `--restore` puts the limit back to off / 100. `--probe` reads only. `--selftest` runs the logic checks. `--render <folder>` draws the panel and icon to PNG files off-screen (no window).

## Building

Cloud: `scripts/cloud-build.sh` (GitHub Actions, manual trigger only). Local, niced, one job: `scripts/local-build.sh`.
Both produce `Charge Keeper.app`, signed ad hoc. Neither installs or launches it.

Install (own Mac): `scripts/install.sh` copies the build into /Applications and opens it. From /Applications the app
adds itself to Login Items once, so it starts with the Mac and cleans up any limit left by a crash or power cut.
