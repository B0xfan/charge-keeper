# Charge Keeper

A planned menu-bar app that stops a MacBook charging at a chosen level. This repo is at Phase 1: a small
command-line proof (`ChargeKeeperProbe`) that finds out which charge-control switches a Mac has, and whether
charging can be stopped and always put back.

Author: John Hesch. Original code. Apple silicon, personal use.

## Commands

- `probe` reads only: lists the charging keys that exist and their values, plus battery state.
- `test [--sleep]` (root) stops charging, checks it, restores, then kills itself to prove a watchdog restores charging.
- `restore` (root) puts the charge-inhibit keys back to "charging on".

Charging is left on by default. Every exit path (normal, Ctrl-C, terminate, kill) restores it; a separate
watchdog process covers the ones that cannot be caught.

## Building

Builds run on GitHub Actions only (manual trigger): `scripts/cloud-build.sh`.
