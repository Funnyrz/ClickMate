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
UNSIGNED_ENTITLEMENTS_DIR="$BUILD_DIR/unsigned-entitlements"
APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/ClickMate.app"
PACKAGED_APP="$DMG_ROOT/ClickMate.app"
ARCHITECTURES=(arm64 x86_64)

cat >&2 <<'WARNING'
======================================================================
WARNING: This package uses an unstable ad-hoc identity.
It can be used for local functional diagnostics, including Finder Extension,
but macOS may require permissions again after every rebuild or replacement.
The App Group entitlement is intentionally removed, so shared Finder settings
and automatic cross-process permission verification are unavailable.
Use package_development_dmg.sh or package_signed_dmg.sh for stable acceptance.
======================================================================
WARNING

echo "==> Cleaning package output"
rm -rf "$DERIVED_DATA" "$DMG_ROOT" "$OUTPUT_DIR" "$UNSIGNED_ENTITLEMENTS_DIR"
mkdir -p "$DMG_ROOT" "$OUTPUT_DIR" "$UNSIGNED_ENTITLEMENTS_DIR"

echo "==> Building unsigned Universal 2 Release app"
xcodebuild build \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS="${ARCHITECTURES[*]}" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  AD_HOC_CODE_SIGNING_ALLOWED=NO

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: expected app was not created at $APP_PATH" >&2
  exit 1
fi

APP_INFO_PLIST="$APP_PATH/Contents/Info.plist"
EXTENSION_INFO_PLIST="$APP_PATH/Contents/PlugIns/ClickMateFinderExtension.appex/Contents/Info.plist"
HELPER_PATH="$APP_PATH/Contents/Library/LoginItems/ClickMateHelper.app"
HELPER_INFO_PLIST="$HELPER_PATH/Contents/Info.plist"
APP_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP_INFO_PLIST")"
EXTENSION_VERSION="$(plutil -extract CFBundleShortVersionString raw "$EXTENSION_INFO_PLIST")"
HELPER_VERSION="$(plutil -extract CFBundleShortVersionString raw "$HELPER_INFO_PLIST")"

if [[ "$APP_VERSION" != "$EXTENSION_VERSION" ]]; then
  echo "error: app version ($APP_VERSION) does not match Finder extension version ($EXTENSION_VERSION)" >&2
  exit 1
fi
if [[ "$APP_VERSION" != "$HELPER_VERSION" ]]; then
  echo "error: app version ($APP_VERSION) does not match Helper version ($HELPER_VERSION)" >&2
  exit 1
fi

DMG_PATH="$OUTPUT_DIR/ClickMate-$APP_VERSION-universal-unsigned.dmg"
echo "==> Packaging ClickMate $APP_VERSION"

echo "==> Verifying Universal 2 architectures"
BINARIES=(
  "$APP_PATH/Contents/MacOS/ClickMate"
  "$APP_PATH/Contents/PlugIns/ClickMateFinderExtension.appex/Contents/MacOS/ClickMateFinderExtension"
  "$HELPER_PATH/Contents/MacOS/ClickMateHelper"
)

for binary in "${BINARIES[@]}"; do
  if [[ ! -f "$binary" ]]; then
    echo "error: expected executable was not created at $binary" >&2
    exit 1
  fi

  if ! lipo "$binary" -verify_arch "${ARCHITECTURES[@]}"; then
    echo "error: executable is not Universal 2: $binary" >&2
    lipo -archs "$binary" >&2 || true
    exit 1
  fi

  echo "    $(basename "$binary"): $(lipo -archs "$binary")"
done

echo "==> Preparing DMG contents"
ditto "$APP_PATH" "$PACKAGED_APP"
ln -s /Applications "$DMG_ROOT/Applications"

echo "==> Applying local ad-hoc signatures"
APP_ENTITLEMENTS=()
if [[ -f "$ROOT_DIR/ClickMate/ClickMate.entitlements" ]]; then
  APP_ENTITLEMENTS_PATH="$UNSIGNED_ENTITLEMENTS_DIR/ClickMate.entitlements"
  cp "$ROOT_DIR/ClickMate/ClickMate.entitlements" "$APP_ENTITLEMENTS_PATH"
  /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.application-groups' "$APP_ENTITLEMENTS_PATH" 2>/dev/null || true
  APP_ENTITLEMENTS=(--entitlements "$APP_ENTITLEMENTS_PATH")
fi

HELPER_ENTITLEMENTS=()
if [[ -f "$ROOT_DIR/ClickMateHelper/ClickMateHelper.entitlements" ]]; then
  HELPER_ENTITLEMENTS=(--entitlements "$ROOT_DIR/ClickMateHelper/ClickMateHelper.entitlements")
fi
codesign \
  --force \
  --sign - \
  --timestamp=none \
  "${HELPER_ENTITLEMENTS[@]}" \
  "$PACKAGED_APP/Contents/Library/LoginItems/ClickMateHelper.app"

while IFS= read -r -d '' bundle; do
  entitlements=()
  if [[ -f "$ROOT_DIR/ClickMateFinderExtension/ClickMateFinderExtension.entitlements" ]]; then
    EXTENSION_ENTITLEMENTS_PATH="$UNSIGNED_ENTITLEMENTS_DIR/ClickMateFinderExtension.entitlements"
    cp "$ROOT_DIR/ClickMateFinderExtension/ClickMateFinderExtension.entitlements" "$EXTENSION_ENTITLEMENTS_PATH"
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.application-groups' "$EXTENSION_ENTITLEMENTS_PATH" 2>/dev/null || true
    entitlements=(--entitlements "$EXTENSION_ENTITLEMENTS_PATH")
  fi
  codesign --force --sign - --timestamp=none "${entitlements[@]}" "$bundle"
done < <(find "$PACKAGED_APP/Contents/PlugIns" -mindepth 1 -maxdepth 1 -type d -name '*.appex' -print0 2>/dev/null || true)

codesign --force --sign - --timestamp=none "${APP_ENTITLEMENTS[@]}" "$PACKAGED_APP"
codesign --verify --deep --strict --verbose=2 "$PACKAGED_APP"

echo "==> Verifying ad-hoc package does not claim App Group access"
for bundle in \
  "$PACKAGED_APP" \
  "$PACKAGED_APP/Contents/PlugIns/ClickMateFinderExtension.appex"; do
  entitlements_plist="$UNSIGNED_ENTITLEMENTS_DIR/$(basename "$bundle").signed-entitlements.plist"
  codesign -d --entitlements :- "$bundle" >"$entitlements_plist" 2>/dev/null
  if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups' "$entitlements_plist" >/dev/null 2>&1; then
    echo "error: ad-hoc bundle still claims App Group access: $bundle" >&2
    exit 1
  fi
done

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
echo "It is for local development and diagnostics only, not release or permission-identity stability acceptance."
echo "Ad-hoc signatures change when the app is rebuilt, so macOS may require TCC permissions again."
echo "App Group access is disabled; Finder settings sync and automatic permission verification are unavailable."
echo "ClickMate will run shortcuts through the session-only Helper fallback."
echo "The Helper keeps running after ClickMate quits, but it is not started automatically after logout or restart."
echo "Recipients may need to remove quarantine after copying the app:"
echo "  xattr -dr com.apple.quarantine /Applications/ClickMate.app"
echo
