#!/bin/bash
# Збірка дво-процесного ShotShot:
#   ShotShotCpp        — резидентний демон (C++, БЕЗ AppKit), ловить ⌘⇧7
#   ShotShotCppEditor  — редактор на вимогу (Obj-C++, AppKit + ScreenCaptureKit)
set -e
cd "$(dirname "$0")"

APP="ShotShotCpp.app"
MACOS="$APP/Contents/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS"

echo "→ Компіляція демона (C++, без AppKit)…"
clang++ -O2 -std=c++17 shotd.cpp -o "$MACOS/ShotShotCpp" \
    -framework ApplicationServices -framework CoreFoundation

echo "→ Компіляція редактора (Obj-C++, AppKit + ScreenCaptureKit)…"
clang++ -O2 -std=c++17 -ObjC++ -fobjc-arc ShotShotCpp.mm -o "$MACOS/ShotShotCppEditor" \
    -framework Cocoa -framework ScreenCaptureKit

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ShotShotCpp</string>
    <key>CFBundleDisplayName</key><string>ShotShotCpp</string>
    <key>CFBundleIdentifier</key><string>com.ek.shotshotcpp</string>
    <key>CFBundleExecutable</key><string>ShotShotCpp</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST

# Підпис: сталий сертифікат ShotShot, якщо є, інакше ad-hoc.
IDENT="ShotShot Dev"
if security find-identity -p codesigning | grep -q "$IDENT"; then
    SIGN="$IDENT"; echo "Підпис: сталий «$IDENT»"
else
    SIGN="-"; echo "Підпис: ad-hoc (дозволи скидатимуться — див. ../setup-signing.sh)"
fi

# Спершу helper зі своїм ідентифікатором, потім головний бінарник і бандл.
codesign --force --sign "$SIGN" -i com.ek.shotshotcpp.editor "$MACOS/ShotShotCppEditor"
codesign --force --sign "$SIGN" -i com.ek.shotshotcpp "$MACOS/ShotShotCpp"
codesign --force --sign "$SIGN" --identifier com.ek.shotshotcpp "$APP"

echo "✅ Готово: cpp/$APP"
echo "   ShotShotCpp       — демон (~2 МБ, крутиться завжди; треба Accessibility)"
echo "   ShotShotCppEditor — редактор на вимогу (треба Screen Recording)"
echo
echo "Запуск:   open cpp/$APP"
echo "Зупинка:  pkill ShotShotCpp"
