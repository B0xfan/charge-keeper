#!/bin/zsh
# Developer ID signing and Apple's check (notarizing) for a cloud build, the route Dateline's release uses:
#   scripts/sign-notarize.sh <ChargeKeeper.zip from the cloud run>
# Signs locally with the hardened runtime (Xcode keeps it when it re-signs), lets Xcode re-sign with the Developer ID certificate
# Apple holds and send it to Apple, then takes back the checked, stapled app into "build/Charge Keeper.app" (what install.sh installs).
# Runs on John's Mac only. The App Store Connect key file stays where it is; nothing is printed from it.
set -euo pipefail
ZIPIN="${1:?Path to the cloud build's ChargeKeeper.zip}"
cd "$(dirname "$0")/.."
ASC_KEY=S93537G5A5; ASC_P8="$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY.p8"
ISS="${ASC_ISSUER_ID:-$( { grep '^ASC_ISSUER_ID=' "$HOME/Projects/A4/.env" 2>/dev/null || true; } | cut -d= -f2- | tr -d '"')}"
[ -f "$ASC_P8" ] && [ -n "$ISS" ] || { echo "App Store Connect key or issuer missing: $ASC_P8, ASC_ISSUER_ID"; exit 1; }
AUTH=(-authenticationKeyPath "$ASC_P8" -authenticationKeyID "$ASC_KEY" -authenticationKeyIssuerID "$ISS")
OUT=build/release; rm -rf "$OUT"; mkdir -p "$OUT"
ditto -x -k "$ZIPIN" "$OUT/in"
APP="$OUT/in/Charge Keeper.app"
VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"); N=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
ID=AB33048703517BE9CB52B2E3781C8B1B00C8A64D  # Apple Development, John's team: Xcode re-signs it with Developer ID
grep -q "$ID" <<<"$(security find-identity -v -p codesigning)" || { echo "Apple Development identity missing: Xcode > Settings > Accounts"; exit 1; }
codesign --force --options runtime --timestamp=none --sign "$ID" "$APP"
AR="$OUT/ChargeKeeper.xcarchive"; mkdir -p "$AR/Products/Applications"; mv "$APP" "$AR/Products/Applications/"
python3 -I - "$AR/Info.plist" "$VER" "$N" <<'PY'
import sys, plistlib, datetime
out, ver, n = sys.argv[1:4]
plistlib.dump({"ArchiveVersion": 2, "Name": "Charge Keeper", "SchemeName": "ChargeKeeper", "CreationDate": datetime.datetime.now(datetime.timezone.utc),
  "ApplicationProperties": {"ApplicationPath": "Applications/Charge Keeper.app", "CFBundleIdentifier": "com.johnhesch.keeper",
  "CFBundleShortVersionString": ver, "CFBundleVersion": n, "Team": "LJZ32VB25F", "Architectures": ["arm64", "x86_64"]}}, open(out, "wb"))
PY
cat > "$OUT/export.plist" <<'EOP'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>method</key><string>developer-id</string><key>signingStyle</key><string>automatic</string>
<key>teamID</key><string>LJZ32VB25F</string><key>destination</key><string>upload</string></dict></plist>
EOP
taskpolicy -b nice -n 19 xcodebuild -exportArchive -archivePath "$AR" -exportOptionsPlist "$OUT/export.plist" -exportPath "$OUT/upload" -allowProvisioningUpdates "${AUTH[@]}" >"$OUT/export.log" 2>&1 \
  || { tail -20 "$OUT/export.log"; echo "Sending to Apple's check failed (full log: $OUT/export.log)"; exit 1; }
echo "Sent to Apple's check; waiting for the answer..."
for i in {1..60}; do   # up to 30 minutes
  xcodebuild -exportNotarizedApp -archivePath "$AR" -exportPath "$OUT/notarized" "${AUTH[@]}" >"$OUT/notarized.log" 2>&1 && break
  grep -qi "invalid\|rejected" "$OUT/notarized.log" && { cat "$OUT/notarized.log"; echo "Apple's check refused the app"; exit 1; }
  [ $i = 60 ] && { tail -5 "$OUT/notarized.log"; echo "No answer from Apple's check after 30 minutes"; exit 1; }
  sleep 30
done
FINAL="$OUT/notarized/Charge Keeper.app"
codesign --verify --strict --verbose=2 "$FINAL"
codesign -d --verbose=2 "$FINAL" 2>&1 | grep -E "Authority=Developer ID Application|flags=.*runtime"
xcrun stapler validate "$FINAL"
SP=$(spctl -a -vvv -t exec "$FINAL" 2>&1); echo "$SP"
grep -q "source=Notarized Developer ID" <<<"$SP" || { echo "Not accepted as a checked Developer ID app"; exit 1; }
ARCHS=" $(lipo -archs "$FINAL/Contents/MacOS/ChargeKeeper") "
[[ "$ARCHS" == *" arm64 "* && "$ARCHS" == *" x86_64 "* ]] || { echo "Not a build for both chips: $ARCHS"; exit 1; }
[ -d "$FINAL/Contents/Resources/Metadata.appintents" ] || { echo "Shortcuts actions' metadata missing"; exit 1; }
taskpolicy -b nice -n 19 "$FINAL/Contents/MacOS/ChargeKeeper" --selftest  # pure logic and a fake helper: no charging change, no Keychain
rm -rf "build/Charge Keeper.app"; ditto "$FINAL" "build/Charge Keeper.app"
ditto -c -k --keepParent "build/Charge Keeper.app" "$OUT/ChargeKeeper-$VER.zip"
echo "Checked: build/Charge Keeper.app and $OUT/ChargeKeeper-$VER.zip (version $VER, build $N)"
