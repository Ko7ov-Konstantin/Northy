#!/bin/sh
set -e

cd "$(dirname "$0")/.."

pkill -x Northy || true

swift build -c release
# Путь бинаря зависит от бэкенда сборки — симлинк .build/release может быть устаревшим.
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="Northy.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

ICON_PNG="scripts/AppIcon1024.png"
ICONSET="scripts/Northy.iconset"
ICNS="scripts/Northy.icns"

# Генерация иконки — только если .icns ещё не собран, не на каждой сборке.
if [ ! -f "$ICNS" ]; then
	echo "Northy.icns отсутствует — генерирую"
	swift scripts/make-icon.swift "$ICON_PNG"
	rm -rf "$ICONSET"
	mkdir -p "$ICONSET"
	sips -z 16 16   "$ICON_PNG" --out "$ICONSET/icon_16x16.png" >/dev/null
	sips -z 32 32   "$ICON_PNG" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
	sips -z 32 32   "$ICON_PNG" --out "$ICONSET/icon_32x32.png" >/dev/null
	sips -z 64 64   "$ICON_PNG" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
	sips -z 128 128 "$ICON_PNG" --out "$ICONSET/icon_128x128.png" >/dev/null
	sips -z 256 256 "$ICON_PNG" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
	sips -z 256 256 "$ICON_PNG" --out "$ICONSET/icon_256x256.png" >/dev/null
	sips -z 512 512 "$ICON_PNG" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
	sips -z 512 512 "$ICON_PNG" --out "$ICONSET/icon_512x512.png" >/dev/null
	cp "$ICON_PNG" "$ICONSET/icon_512x512@2x.png"
	iconutil -c icns "$ICONSET" -o "$ICNS"
	rm -rf "$ICONSET"
fi

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

cat > "$CONTENTS/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.kotov.northy</string>
	<key>CFBundleName</key>
	<string>Northy</string>
	<key>CFBundleExecutable</key>
	<string>Northy</string>
	<key>CFBundleIconFile</key>
	<string>Northy</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.3.0</string>
	<key>CFBundleVersion</key>
	<string>3</string>
	<key>LSUIElement</key>
	<true/>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>Northy записывает звук с микрофона во время записи экрана, если вы это включили.</string>
</dict>
</plist>
EOF

plutil -lint "$CONTENTS/Info.plist"

cp "$BIN_DIR/Northy" "$MACOS/Northy"
cp "$ICNS" "$RESOURCES/Northy.icns"

# Расширение Finder («Отправить в Northy» / «Вставить из Northy»). SwiftPM
# расширения не собирает — отдельный swiftc с точкой входа NSExtensionMain.
# Подписывается до приложения: подпись .app запечатывает вложенный .appex.
EXT_SRC="Extensions/NorthyFinder"
EXT="$CONTENTS/PlugIns/NorthyFinder.appex"
mkdir -p "$EXT/Contents/MacOS"
xcrun swiftc -O -swift-version 5 -module-name NorthyFinder -parse-as-library -application-extension \
	-target arm64-apple-macos26.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
	-framework FinderSync -framework Cocoa \
	-Xlinker -e -Xlinker _NSExtensionMain \
	"$EXT_SRC/FinderSync.swift" -o "$EXT/Contents/MacOS/NorthyFinder"
cp "$EXT_SRC/Info.plist" "$EXT/Contents/Info.plist"
plutil -lint "$EXT/Contents/Info.plist"
# Постоянный сертификат «Northy Dev» из Связки ключей сохраняет разрешения macOS между
# сборками; без него подпись безымянная, и разрешения приходится выдавать заново.
IDENTITY="Northy Dev"
security find-identity -p codesigning | grep -q "\"$IDENTITY\"" || IDENTITY="-"
codesign --force --sign "$IDENTITY" --entitlements "$EXT_SRC/NorthyFinder.entitlements" "$EXT"

codesign --force --sign "$IDENTITY" "$APP"

echo "Собрано: $APP"
echo "Расширение Finder включается один раз: Системные настройки → Основные → Объекты входа и расширения → Finder"
