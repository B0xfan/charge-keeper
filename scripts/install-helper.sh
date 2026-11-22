#!/bin/zsh
# The one step that needs the Mac password: installs the charger helper, which only limits under 80% use.
# Copies the helper out of the installed app, signs the copy, and asks macOS (its standard password box) to put it in
# place as a system helper that starts with the Mac. Run it only when you are expecting the password box.
# --remove takes the helper out again (also asks for the password); removing it switches the charger back on first.
set -euo pipefail
LABEL=com.johnhesch.keeper.helper
BIN=/Library/PrivilegedHelperTools/$LABEL
PLIST=/Library/LaunchDaemons/$LABEL.plist
APPBIN="/Applications/Charge Keeper.app/Contents/MacOS/ChargeKeeper"
PROMPT="Charge Keeper needs your Mac password once to control charging."

STAGE=$(mktemp -d /tmp/ck.XXXXXX)  # fixed, plain path: it is pasted into the root command
trap 'rm -rf "$STAGE"' EXIT
if [[ "${1:-}" == "--remove" ]]; then
    # Stopping the helper switches the charger back on. If its note of a cut is still there, that failed: keep the helper.
    cat > "$STAGE/root.sh" <<EOF
launchctl bootout system/$LABEL 2>/dev/null || true
if [ -e /var/db/$LABEL.cut ]; then launchctl bootstrap system "$PLIST"; echo "Charger power could not be confirmed back on; helper kept." >&2; exit 1; fi
rm -f "$PLIST" "$BIN" /var/run/$LABEL.sock
EOF
else
    [[ -x "$APPBIN" ]] || { echo "Charge Keeper is not installed in /Applications."; exit 1; }
    ditto "$APPBIN" "$STAGE/helper"
    codesign --force -s - -i "$LABEL" "$STAGE/helper" 2>/dev/null
    cat > "$STAGE/helper.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$BIN</string><string>--helper</string><string>$(id -u)</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
</dict>
</plist>
EOF
    plutil -lint -s "$STAGE/helper.plist"
    # Stopping an older helper (bootout) switches the charger back on first; the new one starts with power on.
    cat > "$STAGE/root.sh" <<EOF
set -e
launchctl bootout system/$LABEL 2>/dev/null || true
rm -f /var/run/$LABEL.sock
mkdir -p /Library/PrivilegedHelperTools
install -o root -g wheel -m 755 helper "$BIN"
install -o root -g wheel -m 644 helper.plist "$PLIST"
launchctl bootstrap system "$PLIST"
EOF
fi
# The stage folder is ours, so other programs running as us could swap its files while the password box is open.
# The root step copies them into a root-only folder and runs them only if they match the fingerprint taken now.
# Not covered: a same-user program changing them before this point (it could as easily change the app itself).
FILES=(root.sh); [[ -e "$STAGE/helper" ]] && FILES+=(helper helper.plist)
SUM=$(cd "$STAGE" && shasum -a 256 $FILES | shasum -a 256 | cut -c1-64)
# Self-test after the fingerprint: a helper swapped after the test no longer matches and is refused.
if [[ -e "$STAGE/helper" ]]; then
    "$STAGE/helper" --selftest >/dev/null || { echo "The helper copy failed its self-test; nothing installed."; exit 1; }
fi
SRC=($STAGE/${^FILES})
ROOT="D=\$(mktemp -d /var/root/ck.XXXXXX) && cd \$D && cp ${SRC[*]} . && { shasum -a 256 $FILES | shasum -a 256 | grep -q ^$SUM || { echo Files changed while waiting for the password, nothing installed. >&2; false; }; } && /bin/zsh root.sh; r=\$?; cd /; rm -rf \$D; exit \$r"
osascript -e "do shell script \"$ROOT\" with prompt \"$PROMPT\" with administrator privileges"
if [[ "${1:-}" == "--remove" ]]; then echo "Helper removed."; exit 0; fi
for _ in {1..10}; do [[ -S /var/run/$LABEL.sock ]] && break; sleep 1; done
[[ -S /var/run/$LABEL.sock ]] && echo "Helper installed and running." || { echo "Helper installed but not answering yet."; exit 1; }
