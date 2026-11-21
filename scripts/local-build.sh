#!/bin/zsh
# Niced, one-job local build of the app (both chips, Shortcuts metadata). Does not install or launch anything.
set -euo pipefail
cd "$(dirname "$0")/.."
JOBS=1 taskpolicy -b nice -n 19 scripts/make-app.sh
taskpolicy -b nice -n 19 "build/Charge Keeper.app/Contents/MacOS/ChargeKeeper" --selftest
