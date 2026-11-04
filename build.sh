#!/bin/bash
set -e
cd "$(dirname "$0")"

APP="ShotShot.app"
MACOS="$APP/Contents/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS"

echo "→ Компіляція ShotShot (arm64, нативно)…"
swiftc -O main.swift -o "$MACOS/ShotShot" \
    -framework Cocoa -framework Carbon -framework ScreenCaptureKit

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ShotShot</string>
    <key>CFBundleDisplayName</key><string>ShotShot</string>
    <key>CFBundleIdentifier</key><string>com.ek.shotshot</string>
    <key>CFBundleExecutable</key><string>ShotShot</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST

IDENT="ShotShot Dev"
if security find-identity -p codesigning | grep -q "$IDENT"; then
    codesign --force --deep --sign "$IDENT" "$APP"
    echo "Підпис: сталий «$IDENT» (дозволи переживуть перекомпіляції)"
else
    codesign --force --deep --sign - "$APP"
    echo "Підпис: ad-hoc — запусти ./setup-signing.sh, щоб дозвіл «Запис екрана» не скидався"
fi

echo "✅ Готово: $APP"
echo "Арх:"; file "$MACOS/ShotShot" | sed 's/.*: //'
echo
echo "Запуск:   open $APP"
echo "Зупинка:  pkill ShotShot"