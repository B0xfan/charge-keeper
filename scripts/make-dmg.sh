#!/bin/zsh
# Disk image for the GitHub release: the checked app plus an Applications shortcut to drag it onto, sent to Apple's check and stapled.
#   scripts/make-dmg.sh <checked Charge Keeper.app> <version>   -> build/release/ChargeKeeper-<version>.dmg
# Uses the same App Store Connect key as sign-notarize.sh; nothing is printed from it.
set -euo pipefail
APP="${1:?Path to the checked Charge Keeper.app}"; VER="${2:?Version}"
cd "$(dirname "$0")/.."
ASC_KEY=S93537G5A5; ASC_P8="$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY.p8"
ISS="${ASC_ISSUER_ID:-$( { grep '^ASC_ISSUER_ID=' "$HOME/Projects/A4/.env" 2>/dev/null || true; } | cut -d= -f2- | tr -d '"')}"
[ -f "$ASC_P8" ] && [ -n "$ISS" ] || { echo "App Store Connect key or issuer missing"; exit 1; }
STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Charge Keeper.app"; ln -s /Applications "$STAGE/Applications"
mkdir -p build/release; DMG="build/release/ChargeKeeper-$VER.dmg"; rm -f "$DMG"
hdiutil create -quiet -volname "Charge Keeper" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
xcrun notarytool submit "$DMG" --key "$ASC_P8" --key-id "$ASC_KEY" --issuer "$ISS" --wait | tee build/release/dmg-notary.log
grep -q "status: Accepted" build/release/dmg-notary.log || { echo "Apple's check refused the disk image"; exit 1; }
xcrun stapler staple "$DMG"
# The image itself is unsigned (the Developer ID certificate lives with Apple, not in the keychain); what Gatekeeper checks is the app inside.
MNT=$(mktemp -d); hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MNT" "$DMG"
SP=$(spctl -a -vvv -t exec "$MNT/Charge Keeper.app" 2>&1) || true; hdiutil detach -quiet "$MNT"
grep -q "source=Notarized Developer ID" <<<"$SP" || { echo "$SP"; echo "App inside the disk image not accepted by Gatekeeper"; exit 1; }
echo "Checked: $DMG"
