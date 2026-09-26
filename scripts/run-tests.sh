#!/bin/sh
# Тесты в среде без Xcode: swift test на CLT собирает бандл, но не запускает.
# Поэтому: build-tests -> компилируем dlopen-хост с точкой входа Swift Testing.
# Бэкенд native: swiftbuild (дефолт с Swift 6.4) линкует бандл с XCTest, которого нет в CLT.
set -e
cd "$(dirname "$0")/.."

FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
INTEROP="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
BUNDLE=".build/arm64-apple-macosx/debug/NorthyPackageTests.xctest/Contents/MacOS/NorthyPackageTests"
HOST=".build/test-host"

swift build --build-tests --build-system native
swiftc \
    -F "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$INTEROP" \
    scripts/test-host.swift -o "$HOST"
"$HOST" "$BUNDLE"
