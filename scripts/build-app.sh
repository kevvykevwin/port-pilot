#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/build/PortPilot.app"

echo "Building Port Pilot..."
cd "$PROJECT_DIR"
swift build -c release

echo "Creating .app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp .build/release/PortPilot "$APP_DIR/Contents/MacOS/"
cp Assets/icon.svg "$APP_DIR/Contents/Resources/"

cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>PortPilot</string>
    <key>CFBundleIdentifier</key>
    <string>com.portpilot.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Port Pilot</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "Code signing..."
codesign -s - --force "$APP_DIR"

echo "Done! App at: $APP_DIR"
echo "Binary size: $(du -h "$APP_DIR/Contents/MacOS/PortPilot" | cut -f1)"
echo ""
echo "To install: cp -r $APP_DIR /Applications/"
echo "To run:     open $APP_DIR"
