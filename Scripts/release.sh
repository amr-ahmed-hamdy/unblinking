#!/bin/bash
#
# Builds, signs and packages Unblinking for distribution to other people.
#
# No Apple Developer Program membership? Use ad-hoc signing:
#
#     SIGNING_IDENTITY=- ./Scripts/release.sh
#
# That produces a working DMG. Recipients clear the quarantine flag once, either with
#     xattr -dr com.apple.quarantine /Applications/Unblinking.app
# or via System Settings > Privacy & Security > Open Anyway.
#
# With a paid membership you can notarize instead, so it opens with no warning at all.
# One-time setup for that:
#
#   1. Find your signing identity and Team ID:
#        security find-identity -v -p codesigning
#
#   2. Store an App Store Connect API key or app-specific password in the keychain:
#        xcrun notarytool store-credentials "unblinking-notary" \
#            --apple-id "you@example.com" \
#            --team-id "YOURTEAMID" \
#            --password "abcd-efgh-ijkl-mnop"     # app-specific password
#
# Then:
#
#   DEVELOPMENT_TEAM=YOURTEAMID ./Scripts/release.sh
#
# Optional overrides:
#   NOTARY_PROFILE   keychain profile name          (default: unblinking-notary)
#   SIGNING_IDENTITY codesign identity              (default: Developer ID Application)
#   SKIP_NOTARIZE=1  build and sign only

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/Unblinking.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_PATH="$EXPORT_PATH/Unblinking.app"
ZIP_PATH="$BUILD_DIR/Unblinking.zip"
DMG_PATH="$BUILD_DIR/Unblinking.dmg"

NOTARY_PROFILE="${NOTARY_PROFILE:-unblinking-notary}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application}"
SKIP_NOTARIZE="${SKIP_NOTARIZE:-0}"

# Ad-hoc mode: build a DMG that runs locally without a Developer ID certificate.
# Recipients will have to approve it in System Settings the first time; see the README.
ADHOC=0
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    ADHOC=1
    SKIP_NOTARIZE=1
    DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
    echo "==> Ad-hoc signing: the result will NOT be notarized"
elif [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
    echo "DEVELOPMENT_TEAM is not set." >&2
    echo "Find your Team ID with: security find-identity -v -p codesigning" >&2
    echo >&2
    echo "No Developer ID certificate? Build an unnotarized DMG with:" >&2
    echo "    SIGNING_IDENTITY=- ./Scripts/release.sh" >&2
    exit 1
fi

cd "$PROJECT_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

if [[ "$ADHOC" == "1" ]]; then
    echo "==> Building (ad-hoc)"
    xcodebuild \
        -project Unblinking.xcodeproj \
        -scheme Unblinking \
        -configuration Release \
        -derivedDataPath "$BUILD_DIR/DerivedData" \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGN_STYLE=Manual \
        build
    mkdir -p "$EXPORT_PATH"
    rm -rf "$APP_PATH"
    cp -R "$BUILD_DIR/DerivedData/Build/Products/Release/Unblinking.app" "$APP_PATH"
else

echo "==> Archiving"
xcodebuild archive \
    -project Unblinking.xcodeproj \
    -scheme Unblinking \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"

cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$DEVELOPMENT_TEAM</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
PLIST

echo "==> Exporting"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    -exportPath "$EXPORT_PATH"

fi

echo "==> Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# Hardened Runtime is on, and the app spawns caffeinate, sudo, pmset and osascript.
# Spawning subprocesses is allowed under Hardened Runtime, but confirm the flag is
# actually set, notarization rejects builds without it.
if [[ "$ADHOC" != "1" ]] && ! codesign -d --verbose=2 "$APP_PATH" 2>&1 | grep -q "flags=.*runtime"; then
    echo "Hardened Runtime is not enabled, notarization will reject this." >&2
    exit 1
fi

# The disk image is built either way, an unnotarized DMG is still the easiest way to
# hand someone the app, they just have to approve it once in System Settings.
if [[ "$SKIP_NOTARIZE" == "1" ]]; then
    echo "==> Skipping notarization"
else
    echo "==> Submitting for notarization (this usually takes a few minutes)"
    ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
    xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

    echo "==> Stapling the ticket"
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
fi

echo "==> Building the disk image"
rm -f "$DMG_PATH"
DMG_STAGE="$BUILD_DIR/dmg"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$APP_PATH" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "Unblinking" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG_PATH"

# Re-zip the stapled app so the archive contains the ticket too.
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo
echo "Done."
echo "  App: $APP_PATH"
echo "  Zip: $ZIP_PATH"
echo "  DMG: $DMG_PATH"
echo
if [[ "$SKIP_NOTARIZE" == "1" ]]; then
    echo "NOT notarized. Recipients must approve it once in"
    echo "System Settings > Privacy & Security > Open Anyway."
else
    echo "Both the zip and the DMG are notarized and stapled, anyone can double-click them"
    echo "with no Gatekeeper warning."
fi
