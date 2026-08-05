#!/bin/bash
#
# Builds Unblinking and installs it into /Applications for use on this Mac.
# Ad-hoc signed, fine locally, but see release.sh for something you can send to others.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="Unblinking.app"
DESTINATION="/Applications/$APP_NAME"

cd "$PROJECT_DIR"

echo "==> Building Release"
xcodebuild \
    -project Unblinking.xcodeproj \
    -scheme Unblinking \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_STYLE=Manual \
    build

BUILT_APP="$BUILD_DIR/DerivedData/Build/Products/Release/$APP_NAME"
if [[ ! -d "$BUILT_APP" ]]; then
    echo "Build succeeded but $BUILT_APP is missing." >&2
    exit 1
fi

# A running copy can't be replaced cleanly.
if pgrep -x Unblinking > /dev/null; then
    echo "==> Quitting the running copy"
    osascript -e 'quit app "Unblinking"' 2>/dev/null || pkill -x Unblinking || true
    sleep 1
fi

echo "==> Installing to $DESTINATION"
rm -rf "$DESTINATION"
cp -R "$BUILT_APP" "$DESTINATION"

echo "==> Launching"
open "$DESTINATION"

echo
echo "Done. Look for the coffee cup at the right-hand end of the menu bar."
echo "  Left-click  toggles it on and off"
echo "  Right-click opens durations, closed-lid mode and settings"
