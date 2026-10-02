#!/bin/bash
# Builds Wallpad.app (universal, signed) into dist/: Wallpad.zip, version.txt, install.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="${WALLPAD_REPO:-Altimor/wallpad}"   # GitHub repo the Macs install and update from
BUNDLE_ID="${WALLPAD_BUNDLE_ID:-io.github.altimor.wallpad}"
# Updates must be signed by the same team, so sign with a real identity (also keeps the Accessibility grant).
IDENTITY="${WALLPAD_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)}"
[ -n "$IDENTITY" ] || { echo "no code-signing identity (set WALLPAD_IDENTITY)"; exit 64; }

( cd agent && slowbuild swift build -c release --arch arm64 --arch x86_64 )
VERSION=$(date +%Y%m%d%H%M%S)
OUT="$(mktemp -d)"; APP="$OUT/Wallpad.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp agent/.build/apple/Products/Release/wallpad "$APP/Contents/MacOS/wallpad"
cp agent/Sources/wallpad/remote.html "$APP/Contents/Resources/"
cp assets/AppIcon.icns "$APP/Contents/Resources/"
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
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>WallpadRepo</key><string>$REPO</string>
</dict></plist>
PLIST
codesign --force --deep --options runtime -s "$IDENTITY" "$APP"
rm -rf dist; mkdir dist
( cd "$OUT" && ditto -c -k --keepParent Wallpad.app app.zip ) && mv "$OUT/app.zip" dist/Wallpad.zip
sed "s|__REPO__|$REPO|g; s|__LABEL__|$BUNDLE_ID|g" scripts/install.sh > dist/install.sh
echo "$VERSION" > dist/version.txt
rm -rf "$OUT"
echo "packaged $VERSION"
