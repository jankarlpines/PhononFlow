#!/bin/bash
# Builds PhononFlow.app and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/PhononFlow.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/PhononFlow "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.local.phononflow</string>
  <key>CFBundleName</key><string>PhononFlow</string>
  <key>CFBundleExecutable</key><string>PhononFlow</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>PhononFlow records your voice while you hold the hotkey and transcribes it locally with Phonon-2.</string>
</dict></plist>
PLIST
# Stable self-signed identity keeps the Accessibility grant across rebuilds; falls back to ad-hoc.
ID=$(security find-identity -p codesigning | awk '/PhononFlow Local Signing/{print $2; exit}')
codesign --force --sign "${ID:--}" "$APP"
mkdir -p ~/Applications
rm -rf ~/Applications/PhononFlow.app
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/PhononFlow.app"
