#!/bin/bash
# Installs Wallpad on a TV's Mac (scripts/install-command.sh prints the exact command):
#   curl -fsSL <router>/install.sh | bash -s -- "Lobby TV" <one-time enrollment code>
# Re-running it keeps the same QR code. After that the app updates itself.
set -euo pipefail
NAME="${1:?usage: install.sh \"TV name\" <enrollment code>}"
CODE="${2:?missing enrollment code}"
R=__ROUTER__
LABEL=__LABEL__
APPS="$HOME/Applications"; APP="$APPS/Wallpad.app"; PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
curl -fsSL "$R/wallpad.zip" -o "$TMP/app.zip"
ditto -x -k "$TMP/app.zip" "$TMP/x"
# only install what's signed for this app (same check the auto-updater does)
codesign --verify --deep --strict "$TMP/x/Wallpad.app"

# earlier versions were called "TV Remote"
launchctl bootout "gui/$UID/com.flocrivello.tv-remote" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.flocrivello.tv-remote.plist"; rm -rf "$APPS/TV Remote.app"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
mkdir -p "$APPS"; rm -rf "$APP"; mv "$TMP/x/Wallpad.app" "$APP"

"$APP/Contents/MacOS/wallpad" setup --name "$NAME" --router "$R" --enroll "$CODE"

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/wallpad</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/Wallpad.log</string>
</dict></plist>
PL
launchctl bootstrap "gui/$UID" "$PLIST"

echo
echo "Installed. Two things left on this Mac:"
echo "  1. Allow \"Wallpad\" in System Settings > Privacy & Security > Accessibility (opening it now)."
echo "  2. Print the QR card from the Desktop and stick it on the TV."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true
open -R "$HOME/Desktop/$NAME Wallpad QR.png" || true
