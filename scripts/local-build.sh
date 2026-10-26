#!/bin/zsh
# Niced, one-job local build of the app. Does not install or launch anything.
set -euo pipefail
cd "$(dirname "$0")/.."
taskpolicy -b nice -n 19 swift build -c release -j 1
taskpolicy -b nice -n 19 .build/release/ChargeKeeper --selftest
taskpolicy -b nice -n 19 scripts/make-app.sh
