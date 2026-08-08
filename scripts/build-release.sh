#!/usr/bin/env bash
#
# Baut SplitSound als Release und packt es in ein DMG zum Weitergeben.
#
#   ./scripts/build-release.sh
#
# Signierung: standardmaessig ad-hoc ("-"). Fuer eine Version, die auch auf
# fremden Rechnern ohne Gatekeeper-Warnung startet, eine Developer-ID setzen:
#
#   SIGN_IDENTITY="Developer ID Application: Dein Name (TEAMID)" ./scripts/build-release.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="SplitSound"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
BUILD_DIR="build"
PRODUCT="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
DIST_DIR="dist"

echo "==> Projekt aus project.yml erzeugen"
xcodegen generate

echo "==> Release bauen (Signatur: $SIGN_IDENTITY)"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
  -configuration Release -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES \
  build

[ -d "$PRODUCT" ] || { echo "Build-Produkt fehlt: $PRODUCT" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "$PRODUCT/Contents/Info.plist")
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"

echo "==> DMG bauen: $DMG_PATH"
mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"

# Inhalt des Fensters: die App plus eine Verknuepfung nach /Applications,
# damit der Nutzer nur hinueberziehen muss.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$PRODUCT" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp README.md "$STAGE/LIESMICH.md" 2>/dev/null || true

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" \
  -ov -format UDZO "$DMG_PATH" >/dev/null

echo
echo "Fertig: $DMG_PATH"
if [ "$SIGN_IDENTITY" = "-" ]; then
  echo
  echo "Hinweis: ad-hoc signiert. Auf fremden Rechnern blockiert Gatekeeper die App."
  echo "Dort hilft einmalig: Rechtsklick -> Oeffnen, oder"
  echo "  xattr -dr com.apple.quarantine /Applications/$APP_NAME.app"
fi
