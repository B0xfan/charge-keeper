#!/bin/zsh
# The one step that needs John's Mac password: installs the charger helper, which only limits under 80% use.
# Copies the helper out of the installed app, signs the copy, and asks macOS (its standard password box) to put it in
# place as a system helper that starts with the Mac. Run it only when John is expecting the password box.
# --remove takes the helper out again (also asks for the password); removing it switches the charger back on first.
set -euo pipefail
LABEL=com.johnhesch.keeper.helper
BIN=/Library/PrivilegedHelperTools/$LABEL
PLIST=/Library/LaunchDaemons/$LABEL.plist
APPBIN="/Applications/Charge Keeper.app/Contents/MacOS/ChargeKeeper"
PROMPT="Charge Keeper needs your Mac password once to control charging."

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
if [[ "${1:-}" == "--remove" ]]; then
    # Stopping the helper switches the charger back on. If its note of a cut is still there, that failed: keep the helper.
    cat > "$STAGE/root.sh" <<EOF
launchctl bootout system/$LABEL 2>/dev/null || true
if [ -e /var/db/$LABEL.cut ]; then launchctl bootstrap system "$PLIST"; echo "Charger power could not be confirmed back on; helper kept."; exit 1; fi
rm -f "$PLIST" "$BIN" /var/run/$LABEL.sock
EOF
else
    [[ -x "$APPBIN" ]] || { echo "Charge Keeper is not installed in /Applications."; exit 1; }
    ditto "$APPBIN" "$STAGE/helper"
    codesign --force -s - -i "$LABEL" "$STAGE/helper" 2>/dev/null
    "$STAGE/helper" --selftest >/dev/null || { echo "The helper copy failed its self-test; nothing installed."; exit 1; }
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
install -o root -g wheel -m 755 "$STAGE/helper" "$BIN"
install -o root -g wheel -m 644 "$STAGE/helper.plist" "$PLIST"
launchctl bootstrap system "$PLIST"
EOF
fi
chmod 700 "$STAGE"
osascript -e "do shell script \"/bin/zsh '$STAGE/root.sh'\" with prompt \"$PROMPT\" with administrator privileges"
if [[ "${1:-}" == "--remove" ]]; then echo "Helper removed."; exit 0; fi
for _ in {1..10}; do [[ -S /var/run/$LABEL.sock ]] && break; sleep 1; done
[[ -S /var/run/$LABEL.sock ]] && echo "Helper installed and running." || { echo "Helper installed but not answering yet."; exit 1; }
