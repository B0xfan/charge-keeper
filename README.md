# Charge Keeper

A planned menu-bar app that stops a MacBook charging at a chosen level. This repo is at Phase 1: a small
command-line proof (`ChargeKeeperProbe`) that finds out which charge-control switches a Mac has, and whether
charging can be stopped and always put back.

Author: John Hesch. Original code. Apple silicon, personal use.

## Commands

Phase 1 uses macOS's own built-in charge limit (the private PowerUI framework). No charging-chip key is written.
No root needed: the tool talks to the user's own PowerUI service.

- `probe` reads only: is the limit supported, on or off, which level, offered steps, battery state.
- `test [pct] [--try89]` sets the limit (default 90), verifies it, restores, then kills itself to prove a watchdog restores it.
- `restore` puts the limit back to off / 100.

The setting is always put back: every exit path (normal, Ctrl-C, terminate) restores it; a separate watchdog process
covers the ones that cannot be caught (kill -9).

## Building

Builds run on GitHub Actions only (manual trigger): `scripts/cloud-build.sh`.
