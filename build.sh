#!/bin/bash
# Builds StrataBar.app into ~/Applications (or the folder given as $1). Needs the Command Line Tools (swiftc).
set -euo pipefail
cd "$(dirname "$0")"

DEST="${1:-$HOME/Applications}"
APP="$DEST/StrataBar.app"
SWIFTC=(swiftc -parse-as-library -swift-version 5 -O -target arm64-apple-macos15)

mkdir -p build
"${SWIFTC[@]}" Sources/StrataBar.swift Sources/StrataIcon.swift -o build/StrataBar
"${SWIFTC[@]}" Sources/MakeIcon.swift Sources/StrataIcon.swift -o build/make-icon
rm -rf build/AppIcon.iconset
build/make-icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns

pkill -x StrataBar 2>/dev/null || true          # the old copy; the model keeps running (launchd owns it)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/StrataBar "$APP/Contents/MacOS/StrataBar"
cp Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"                # ad-hoc: fine for a build made on this Mac
echo "built $APP"
