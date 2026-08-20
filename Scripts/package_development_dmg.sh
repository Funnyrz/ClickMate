#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/ClickMate.xcodeproj"
SCHEME="ClickMate"
CONFIGURATION="Release"
BUILD_DIR="$ROOT_DIR/build/development"
DERIVED_DATA="$BUILD_DIR/DerivedData"
DMG_ROOT="$BUILD_DIR/dmg-root"
OUTPUT_DIR="$ROOT_DIR/build/dist"
APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/ClickMate.app"
PACKAGED_APP="$DMG_ROOT/ClickMate.app"
ARCHITECTURES=(arm64 x86_64)

DEVELOPMENT_TEAM="${CLICKMATE_DEVELOPMENT_TEAM:-}"
SIGNING_IDENTITY="${CLICKMATE_DEVELOPMENT_IDENTITY:-Apple Development}"

if [[ -z "$DEVELOPMENT_TEAM" ]]; then
  echo "error: CLICKMATE_DEVELOPMENT_TEAM is required" >&2
  exit 1
fi


echo "==> Cleaning development package output"
rm -rf "$BUILD_DIR"
mkdir -p "$DMG_ROOT" "$OUTPUT_DIR"

echo "==> Building Xcode-provisioned Apple Development Universal 2 app"
xcodebuild build \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates \
  ARCHS="${ARCHITECTURES[*]}" \
  ONLY_ACTIVE_ARCH=NO \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  ENABLE_HARDENED_RUNTIME=YES

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: expected app was not created at $APP_PATH" >&2
  exit 1
fi

HELPER_PATH="$APP_PATH/Contents/Library/LoginItems/ClickMateHelper.app"
EXTENSION_PATH="$APP_PATH/Contents/PlugIns/ClickMateFinderExtension.appex"

BUNDLES=("$APP_PATH" "$HELPER_PATH" "$EXTENSION_PATH")
EXPECTED_BUNDLE_IDS=(
  "com.zxacn.clickmate"
  "com.zxacn.clickmate.Helper"
  "com.zxacn.clickmate.FinderExtension"
)

echo "==> Verifying identities, Team IDs, Bundle IDs, and architectures"
for index in "${!BUNDLES[@]}"; do
  bundle="${BUNDLES[$index]}"
  expected_bundle_id="${EXPECTED_BUNDLE_IDS[$index]}"
  info_plist="$bundle/Contents/Info.plist"
  executable_name="$(plutil -extract CFBundleExecutable raw "$info_plist")"
  executable="$bundle/Contents/MacOS/$executable_name"
  actual_bundle_id="$(plutil -extract CFBundleIdentifier raw "$info_plist")"
  signature_details="$(codesign -dv --verbose=4 "$bundle" 2>&1)"
  team_id="$(sed -n 's/^TeamIdentifier=//p' <<<"$signature_details")"
  entitlements_plist="$BUILD_DIR/entitlements-$index.plist"
  codesign -d --entitlements :- "$bundle" 2>/dev/null >"$entitlements_plist"

  if [[ "$actual_bundle_id" != "$expected_bundle_id" ]]; then
    echo "error: expected $expected_bundle_id, found $actual_bundle_id" >&2
    exit 1
  fi
  if [[ -z "$team_id" || "$team_id" != "$DEVELOPMENT_TEAM" ]]; then
    echo "error: $actual_bundle_id has Team ID '$team_id', expected '$DEVELOPMENT_TEAM'" >&2
    exit 1
  fi
  if grep -q '^Signature=adhoc$' <<<"$signature_details"; then
    echo "error: $actual_bundle_id is ad-hoc signed" >&2
    exit 1
  fi
  if ! grep -q '^Authority=Apple Development:' <<<"$signature_details"; then
    echo "error: $actual_bundle_id is not signed with an Apple Development certificate" >&2
    exit 1
  fi
  if ! grep -q 'flags=.*runtime' <<<"$signature_details"; then
    echo "error: $actual_bundle_id does not have hardened runtime enabled" >&2
    exit 1
  fi
  if ! lipo "$executable" -verify_arch "${ARCHITECTURES[@]}"; then
    echo "error: executable is not Universal 2: $executable" >&2
    exit 1
  fi

  if [[ "$actual_bundle_id" == "com.zxacn.clickmate" || "$actual_bundle_id" == "com.zxacn.clickmate.FinderExtension" ]]; then
    expected_application_identifier="$DEVELOPMENT_TEAM.$actual_bundle_id"
    application_identifier="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$entitlements_plist" 2>/dev/null || true)"
    entitlement_team_id="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$entitlements_plist" 2>/dev/null || true)"
    app_group="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$entitlements_plist" 2>/dev/null || true)"
    provisioning_profile="$bundle/Contents/embedded.provisionprofile"

    if [[ "$application_identifier" != "$expected_application_identifier" ]]; then
      echo "error: $actual_bundle_id has application identifier '$application_identifier', expected '$expected_application_identifier'" >&2
      exit 1
    fi
    if [[ "$entitlement_team_id" != "$DEVELOPMENT_TEAM" ]]; then
      echo "error: $actual_bundle_id has entitlement Team ID '$entitlement_team_id', expected '$DEVELOPMENT_TEAM'" >&2
      exit 1
    fi
    if [[ "$app_group" != "group.com.zxacn" ]]; then
      echo "error: $actual_bundle_id is missing the expected App Group entitlement" >&2
      exit 1
    fi
    if [[ ! -f "$provisioning_profile" ]]; then
      echo "error: $actual_bundle_id is missing an embedded provisioning profile" >&2
      exit 1
    fi
    profile_plist="$BUILD_DIR/provisioning-profile-$index.plist"
    security cms -D -i "$provisioning_profile" >"$profile_plist"
    provisioned_app_group="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.security.application-groups:0' "$profile_plist" 2>/dev/null || true)"
    if [[ "$provisioned_app_group" != "group.com.zxacn" ]]; then
      echo "error: $actual_bundle_id provisioning profile does not authorize group.com.zxacn" >&2
      echo "error: refusing to package a build that can trigger repeated 'access other app data' prompts" >&2
      exit 1
    fi
  fi
done

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

APP_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")"
BUILD_VERSION="$(plutil -extract CFBundleVersion raw "$APP_PATH/Contents/Info.plist")"
DMG_PATH="$OUTPUT_DIR/ClickMate-$APP_VERSION-$BUILD_VERSION-development.dmg"

echo "==> Preparing DMG"
ditto "$APP_PATH" "$PACKAGED_APP"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create \
  -volname "ClickMate Development" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo
echo "Created: $DMG_PATH"
echo "Team ID: $DEVELOPMENT_TEAM"
echo "This build is for local permission and Finder Extension acceptance only."
