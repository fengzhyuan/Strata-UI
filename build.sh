#!/bin/bash
# Builds StrataBar.app into /Applications (~/Applications when this account cannot write there), or into the folder
# given as $1. Needs the Command Line Tools (swiftc).
set -euo pipefail
cd "$(dirname "$0")"

if [ $# -ge 1 ]; then
  DEST="$1"
elif [ -w /Applications ]; then
  DEST=/Applications
else
  DEST="$HOME/Applications"                     # a standard account: /Applications takes an administrator
  echo "/Applications is not writable for this account: installing into $DEST"
fi
APP="$DEST/StrataBar.app"
SWIFTC=(swiftc -parse-as-library -swift-version 5 -O -target arm64-apple-macos15)

mkdir -p build
"${SWIFTC[@]}" Sources/StrataBar.swift Sources/SetupWindow.swift Sources/StrataIcon.swift -o build/StrataBar
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
