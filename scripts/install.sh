#!/bin/bash
# Installs Wallpad on the Mac behind a TV:
#   curl -fsSL https://github.com/__REPO__/releases/latest/download/install.sh | bash
# Optional TV name (defaults to the Mac's name): ... | bash -s -- "Lobby TV". Re-running keeps the same QR code.
set -euo pipefail
NAME="${1:-}"
LABEL=__LABEL__
APPS="$HOME/Applications"; APP="$APPS/Wallpad.app"; PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
curl -fsSL "https://github.com/__REPO__/releases/latest/download/Wallpad.zip" -o "$TMP/app.zip"
ditto -x -k "$TMP/app.zip" "$TMP/x"
codesign --verify --deep --strict "$TMP/x/Wallpad.app"

# earlier versions were called "TV Remote"
launchctl bootout "gui/$UID/com.flocrivello.tv-remote" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.flocrivello.tv-remote.plist"; rm -rf "$APPS/TV Remote.app"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
mkdir -p "$APPS"; rm -rf "$APP"; mv "$TMP/x/Wallpad.app" "$APP"
if [ -n "$NAME" ]; then "$APP/Contents/MacOS/wallpad" setup --name "$NAME"; else "$APP/Contents/MacOS/wallpad" setup; fi

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
echo "Installed. Last two steps:"
echo "  1. Turn on Wallpad in System Settings > Privacy & Security > Accessibility (opening it now)."
echo "  2. Print the QR card from the Desktop and stick it on the TV."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true
open -R "$HOME/Desktop/"*" Wallpad QR.png" 2>/dev/null || true
