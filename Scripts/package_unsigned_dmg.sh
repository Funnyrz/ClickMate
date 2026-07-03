#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/ClickMate.xcodeproj"
SCHEME="ClickMate"
CONFIGURATION="Release"
BUILD_DIR="$ROOT_DIR/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
DMG_ROOT="$BUILD_DIR/dmg-root"
OUTPUT_DIR="$BUILD_DIR/dist"
APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/ClickMate.app"
PACKAGED_APP="$DMG_ROOT/ClickMate.app"
DMG_PATH="$OUTPUT_DIR/ClickMate-unsigned.dmg"

echo "==> Cleaning package output"
rm -rf "$DERIVED_DATA" "$DMG_ROOT" "$OUTPUT_DIR"
mkdir -p "$DMG_ROOT" "$OUTPUT_DIR"

echo "==> Building unsigned Release app"
xcodebuild build \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  AD_HOC_CODE_SIGNING_ALLOWED=NO

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: expected app was not created at $APP_PATH" >&2
  exit 1
fi

echo "==> Preparing DMG contents"
ditto "$APP_PATH" "$PACKAGED_APP"
ln -s /Applications "$DMG_ROOT/Applications"

echo "==> Applying local ad-hoc signatures"
APP_ENTITLEMENTS=()
if [[ -f "$ROOT_DIR/ClickMate/ClickMate.entitlements" ]]; then
  APP_ENTITLEMENTS=(--entitlements "$ROOT_DIR/ClickMate/ClickMate.entitlements")
fi

while IFS= read -r -d '' bundle; do
  entitlements=()
  if [[ -f "$ROOT_DIR/ClickMateFinderExtension/ClickMateFinderExtension.entitlements" ]]; then
    entitlements=(--entitlements "$ROOT_DIR/ClickMateFinderExtension/ClickMateFinderExtension.entitlements")
  fi
  codesign --force --sign - --timestamp=none "${entitlements[@]}" "$bundle"
done < <(find "$PACKAGED_APP/Contents/PlugIns" -mindepth 1 -maxdepth 1 -type d -name '*.appex' -print0 2>/dev/null || true)

codesign --force --sign - --timestamp=none "${APP_ENTITLEMENTS[@]}" "$PACKAGED_APP"
codesign --verify --deep --strict --verbose=2 "$PACKAGED_APP"

echo "==> Creating DMG"
hdiutil create \
  -volname "ClickMate" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo
echo "Created: $DMG_PATH"
echo
echo "This DMG is not Developer ID signed or notarized."
echo "Recipients may need to remove quarantine after copying the app:"
echo "  xattr -dr com.apple.quarantine /Applications/ClickMate.app"
echo
