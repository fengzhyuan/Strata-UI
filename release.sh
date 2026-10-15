#!/bin/bash
# Builds StrataBar for a GitHub release: signed with a Developer ID, notarized by Apple and stapled, so it opens on
# any Mac without a Gatekeeper prompt. Writes build/release/StrataBar-<version>.zip. For a build used only on this
# Mac, ./build.sh is enough.
#
# Needs, once per Mac (a paid Apple Developer Program membership):
#   - a "Developer ID Application" certificate with its private key in the keychain
#     (Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application)
#   - a notarytool profile: xcrun notarytool store-credentials strata-notary --apple-id <Apple ID> --team-id <team ID>
# SIGN_IDENTITY and NOTARY_PROFILE choose others than the defaults below.
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
PROFILE="${NOTARY_PROFILE:-strata-notary}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
OUT=build/release
APP="$OUT/StrataBar.app"
ZIP="$OUT/StrataBar-$VERSION.zip"
SWIFTC=(swiftc -parse-as-library -swift-version 5 -O -target arm64-apple-macos15)

# its own build, apart from build.sh's: build.sh replaces the installed app (and quits it)
rm -rf "$OUT"
mkdir -p "$OUT"
"${SWIFTC[@]}" Sources/StrataBar.swift Sources/StrataIcon.swift -o "$OUT/StrataBar"
"${SWIFTC[@]}" Sources/MakeIcon.swift Sources/StrataIcon.swift -o "$OUT/make-icon"
"$OUT/make-icon" "$OUT/AppIcon.iconset"
iconutil -c icns "$OUT/AppIcon.iconset" -o "$OUT/AppIcon.icns"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/StrataBar" "$APP/Contents/MacOS/StrataBar"
cp Info.plist "$APP/Contents/Info.plist"
cp "$OUT/AppIcon.icns" "$APP/Contents/Resources/"

# the hardened runtime and a secure timestamp: notarization requires both
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# notarize a zip of the app, then staple the ticket to the app itself (so it also opens offline) and zip that
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
RESULT=$(xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$PROFILE" --wait --output-format json)
STATUS=$(plutil -extract status raw -o - - <<< "$RESULT")
if [ "$STATUS" != "Accepted" ]; then
  echo "notarization: $STATUS" >&2
  xcrun notarytool log "$(plutil -extract id raw -o - - <<< "$RESULT")" --keychain-profile "$PROFILE" >&2 || true
  exit 1
fi
rm "$OUT/notarize.zip"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "release: $ZIP"
