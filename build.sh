#!/bin/zsh
# Build LangSwap.app for this Mac and install it to ~/Applications.
# Needs Apple's free command-line tools:  xcode-select --install
set -e
cd "$(dirname "$0")"
VERSION="4.0"
APP="$HOME/Applications/LangSwap.app"
pkill -x LangSwap 2>/dev/null || true
swiftc -O -swift-version 5 main.swift -o LangSwap -framework AppKit -framework Carbon -framework ServiceManagement
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv LangSwap "$APP/Contents/MacOS/LangSwap"
cp resources/en_50k.txt resources/he_50k.txt NOTICE.md "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>app.langswap.mac</string>
  <key>CFBundleName</key><string>LangSwap</string>
  <key>CFBundleExecutable</key><string>LangSwap</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Installed: $APP"
echo "Open it with:  open \"$APP\"   (then allow it in System Settings > Privacy & Security > Accessibility)"
