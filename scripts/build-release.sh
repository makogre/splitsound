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

# --- Smoke check -------------------------------------------------------------
# Launches the built app and verifies it can actually interpret Core Audio's
# process objects. This exists because of a bug that appeared *only* in
# optimised builds: the property readers returned nothing, every process was
# discarded, and the mixer stayed permanently empty. No unit test reproduces
# it — the test bundle is optimised differently — so the built app is checked
# directly. See docs/TECHNICAL.md.
echo "==> Smoke check on the built app"
SINCE=$(date "+%Y-%m-%d %H:%M:%S")
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 1
open "$PRODUCT"
sleep 5

REFRESH=$(log show --start "$SINCE" \
  --predicate 'subsystem == "com.maxgrell.SplitSound" AND category == "ProcessMonitor"' \
  --info 2>/dev/null | grep -o 'refresh: [0-9]* audio object(s), [0-9]* usable' | tail -1)
pkill -x "$APP_NAME" 2>/dev/null || true

if [ -z "$REFRESH" ]; then
  # Not skipped quietly: a check that silently passes is worse than no check.
  echo "  FAILED: the app logged no process refresh at all." >&2
  echo "  Either it did not start, or monitoring never ran." >&2
  exit 1
else
  USABLE=$(echo "$REFRESH" | sed -E 's/.*, ([0-9]+) usable/\1/')
  echo "  $REFRESH"
  if [ "$USABLE" -eq 0 ]; then
    echo "  FAILED: the app sees audio objects but can interpret none of them." >&2
    echo "  This is the optimised-build reader bug. Do not ship this build." >&2
    exit 1
  fi
  echo "  ok"
fi

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
