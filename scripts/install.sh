#!/bin/zsh
# The one install step: puts the locally built, signed app into /Applications (replacing an older copy) and opens it.
# Quitting the old copy first lets it put charging back to normal; the new copy then sets its own limit.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="build/Charge Keeper.app"
DST="/Applications/Charge Keeper.app"
[[ -d "$SRC" ]] || { echo "No build found. Run scripts/local-build.sh first."; exit 1; }
codesign --verify --strict "$SRC"
if pgrep -x ChargeKeeper >/dev/null; then
    pkill -TERM -x ChargeKeeper
    for _ in {1..20}; do pgrep -x ChargeKeeper >/dev/null || break; sleep 1; done
    ! pgrep -x ChargeKeeper >/dev/null || { echo "The old copy did not quit."; exit 1; }
fi
rm -rf "$DST"
ditto "$SRC" "$DST"
open "$DST"
echo "Installed: $DST"
