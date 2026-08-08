#!/usr/bin/env bash
#
# Builds SplitSound in Release configuration and packages it into a DMG.
#
#   ./scripts/build-release.sh
#
# Signing defaults to ad-hoc ("-"). For a build that starts on other machines
# without a Gatekeeper warning, supply a Developer ID:
#
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build-release.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="SplitSound"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
BUILD_DIR="build"
PRODUCT="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
DIST_DIR="dist"

echo "==> Generating project from project.yml"
xcodegen generate

echo "==> Building Release (signature: $SIGN_IDENTITY)"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
  -configuration Release -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES \
  build

[ -d "$PRODUCT" ] || { echo "Build product missing: $PRODUCT" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "$PRODUCT/Contents/Info.plist")
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"

echo "==> Building DMG: $DMG_PATH"
mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"

# Window contents: the app plus a shortcut to /Applications, so the user only
# has to drag it across.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$PRODUCT" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp README.md "$STAGE/README.md" 2>/dev/null || true

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" \
  -ov -format UDZO "$DMG_PATH" >/dev/null

echo
echo "Done: $DMG_PATH"
if [ "$SIGN_IDENTITY" = "-" ]; then
  echo
  echo "Note: ad-hoc signed. Gatekeeper will block the app on other machines."
  echo "There, one of these helps: right-click -> Open, or"
  echo "  xattr -dr com.apple.quarantine /Applications/$APP_NAME.app"
fi
