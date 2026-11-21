#!/bin/zsh
# Builds "build/Charge Keeper.app": one program for Apple chips and Intel (arm64 + x86_64), the Shortcuts actions' metadata
# (Metadata.appintents, which plain `swift build` does not make), signed ad hoc with the hardened runtime. Developer ID signing
# and Apple's check come after, in scripts/sign-notarize.sh. JOBS sets the compile jobs (default 2; local-build.sh uses 1).
set -euo pipefail
cd "$(dirname "$0")/.."
J=${JOBS:-2}
APP="build/Charge Keeper.app"
TC=$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")  # .../XcodeDefault.xctoolchain
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
# The protocols whose types the compiler writes out for the metadata step: the list Xcode itself ships, or the same list by hand.
LIST="$TC/usr/share/swift/SwiftConstantValues/AppIntents.json"
if [[ -f "$LIST" ]]; then python3 -I -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["constValueProtocols"]))' "$LIST" > "$WORK/protocols.json"
else echo '["AppIntent","AppEntity","TransientEntity","AppEnum","EntityQuery","DynamicOptionsProvider","AppShortcutsProvider","AppShortcutProviding","AnyResolverProviding","Resolver","AppIntentsPackage","_IntentValueRepresentable","_AssistantIntentsProvider"]' > "$WORK/protocols.json"; fi
ARM=(-c release -j "$J" --triple arm64-apple-macosx14.0 --build-path .build/arm64)
X86=(-c release -j "$J" --triple x86_64-apple-macosx14.0 --build-path .build/x86_64)
swift build "${ARM[@]}" -Xswiftc -emit-const-values -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file -Xswiftc -Xfrontend -Xswiftc "$WORK/protocols.json"
swift build "${X86[@]}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$(swift build "${ARM[@]}" --show-bin-path)/ChargeKeeper" "$(swift build "${X86[@]}" --show-bin-path)/ChargeKeeper" -output "$APP/Contents/MacOS/ChargeKeeper"
cp App/Info.plist "$APP/Contents/Info.plist"
cp scripts/install-helper.sh "$APP/Contents/Resources/install-helper.sh"  # the panel's Install/Update Charger Helper button runs it
# The Shortcuts actions: Apple's metadata step, as Xcode runs it, over the arm64 build's constant values.
find .build/arm64 -name '*.swiftconstvalues' > "$WORK/constvalues.txt"
print -l "$PWD"/Sources/ChargeKeeper/*.swift > "$WORK/sources.txt"
xcrun appintentsmetadataprocessor --force --output "$APP/Contents/Resources" --toolchain-dir "$TC" --module-name ChargeKeeper \
    --sdk-root "$(xcrun --show-sdk-path --sdk macosx)" --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
    --platform-family macOS --deployment-target 14.0 --target-triple arm64-apple-macosx14.0 \
    --source-file-list "$WORK/sources.txt" --swift-const-vals-list "$WORK/constvalues.txt"
ACTIONS="$APP/Contents/Resources/Metadata.appintents/extract.actionsdata"
for a in SetChargeLimitIntent ChargeToFullOnceIntent GoBackToLimitIntent RunDownIntent SetHeatPauseIntent SetSailingRangeIntent GetBatteryStatusIntent; do
    grep -q "\"$a\"" "$ACTIONS" || { echo "Shortcuts action missing from the metadata: $a"; exit 1; }
done
codesign --force --options runtime -s - "$APP"
lipo -archs "$APP/Contents/MacOS/ChargeKeeper"
echo "$APP"
