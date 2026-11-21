#!/bin/zsh
# Wraps the release binary into "build/Charge Keeper.app" and signs it ad hoc (local use only). Run after `swift build -c release`.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/Charge Keeper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/ChargeKeeper" "$APP/Contents/MacOS/ChargeKeeper"
cp App/Info.plist "$APP/Contents/Info.plist"
cp scripts/install-helper.sh "$APP/Contents/Resources/install-helper.sh"  # the panel's Install/Update Charger Helper button runs it
codesign --force -s - "$APP"
echo "$APP"
