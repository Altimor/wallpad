#!/bin/bash
# Builds Wallpad.app (universal, signed) and puts the zip, version and installer where the router serves them.
#   WALLPAD_ROUTER=https://wallpad.<you>.workers.dev scripts/package.sh   (or put the URL in .router)
set -euo pipefail
cd "$(dirname "$0")/.."
ROUTER="${WALLPAD_ROUTER:-$(cat .router 2>/dev/null || true)}"
[ -n "$ROUTER" ] || { echo "set WALLPAD_ROUTER or write the router URL to .router"; exit 64; }
BUNDLE_ID="${WALLPAD_BUNDLE_ID:-io.github.altimor.wallpad}"
# Updates must be signed by the same team, so sign with a real identity (also keeps the Accessibility grant).
IDENTITY="${WALLPAD_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)}"
[ -n "$IDENTITY" ] || { echo "no code-signing identity (set WALLPAD_IDENTITY)"; exit 64; }

( cd agent && slowbuild swift build -c release --arch arm64 --arch x86_64 )
VERSION=$(date +%Y%m%d%H%M%S)   # Macs update themselves when worker/public/version.txt changes
OUT="$(mktemp -d)"; APP="$OUT/Wallpad.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp agent/.build/apple/Products/Release/wallpad "$APP/Contents/MacOS/wallpad"
cp agent/Sources/wallpad/remote.html "$APP/Contents/Resources/"
[ -f assets/AppIcon.icns ] && cp assets/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Wallpad</string>
  <key>CFBundleExecutable</key><string>wallpad</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>WallpadRouter</key><string>$ROUTER</string>
</dict></plist>
PLIST
codesign --force --deep --options runtime -s "$IDENTITY" "$APP"
mkdir -p worker/public
( cd "$OUT" && ditto -c -k --keepParent Wallpad.app app.zip )
cp "$OUT/app.zip" worker/public/wallpad.zip
sed "s|__ROUTER__|$ROUTER|g; s|__LABEL__|$BUNDLE_ID|g" scripts/install.sh > worker/public/install.sh
echo "$VERSION" > worker/public/version.txt
rm -f worker/public/tv-remote.zip
rm -rf "$OUT"
echo "packaged $VERSION for $ROUTER"
