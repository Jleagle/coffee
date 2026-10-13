#!/bin/sh
# Wraps a coffee-menubar binary into Coffee.app. Shared by the release
# workflow and run.sh so the Info.plist (bundle ID, notification style…)
# lives in one place.
#
#   bundle.sh <binary> <version> <output.app>
set -eu

BIN="$1"
VERSION="$2"
APP="$3"
HERE="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Copy then rename: replacing the executable in place would kill a running
# dev instance with an invalid-signature SIGKILL.
cp "$BIN" "$APP/Contents/MacOS/coffee-menubar.new"
mv -f "$APP/Contents/MacOS/coffee-menubar.new" "$APP/Contents/MacOS/coffee-menubar"
cp "$HERE/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Coffee</string>
  <key>CFBundleDisplayName</key><string>Coffee</string>
  <key>CFBundleIdentifier</key><string>com.jleagle.coffee</string>
  <key>CFBundleExecutable</key><string>coffee-menubar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <!-- Ask for the persistent Alerts notification style. macOS 26 ignores this
       for ad-hoc signed apps (verified 2026-09), so the README also tells
       users to pick Alerts in System Settings. -->
  <key>NSUserNotificationAlertStyle</key><string>alert</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature so the assembled bundle is coherent (arm64 requires at
# least an ad-hoc signature to launch).
codesign --force --sign - "$APP"
