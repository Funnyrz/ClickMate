#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/ClickMate.xcodeproj"
SCHEME="ClickMate"
CONFIGURATION="Release"
BUILD_DIR="$ROOT_DIR/build/signed"
ARCHIVE_PATH="$BUILD_DIR/ClickMate.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS_PLIST="$BUILD_DIR/ExportOptions.plist"
DMG_ROOT="$BUILD_DIR/dmg-root"
OUTPUT_DIR="$ROOT_DIR/build/dist"
APP_PATH="$EXPORT_DIR/ClickMate.app"
PACKAGED_APP="$DMG_ROOT/ClickMate.app"
ARCHITECTURES=(arm64 x86_64)

DEVELOPMENT_TEAM="${CLICKMATE_DEVELOPMENT_TEAM:-}"
SIGNING_IDENTITY="${CLICKMATE_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${CLICKMATE_NOTARY_PROFILE:-}"

if [[ -z "$DEVELOPMENT_TEAM" ]]; then
  echo "error: CLICKMATE_DEVELOPMENT_TEAM is required for App Group provisioning" >&2
  exit 1
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo "error: CLICKMATE_SIGNING_IDENTITY must name a Developer ID Application identity" >&2
  exit 1
fi

if [[ "$SIGNING_IDENTITY" != Developer\ ID\ Application:* ]]; then
  echo "error: CLICKMATE_SIGNING_IDENTITY must be a Developer ID Application identity" >&2
  exit 1
fi

if [[ -z "$NOTARY_PROFILE" ]]; then
  echo "error: CLICKMATE_NOTARY_PROFILE is required for a release artifact" >&2
  exit 1
fi

if ! security find-identity -v -p codesigning | grep -Fq "\"$SIGNING_IDENTITY\""; then
  echo "error: signing identity was not found: $SIGNING_IDENTITY" >&2
  exit 1
fi

echo "==> Cleaning signed package output"
rm -rf "$BUILD_DIR"
mkdir -p "$EXPORT_DIR" "$DMG_ROOT" "$OUTPUT_DIR"

plutil -create xml1 "$EXPORT_OPTIONS_PLIST"
plutil -insert destination -string export "$EXPORT_OPTIONS_PLIST"
plutil -insert method -string developer-id "$EXPORT_OPTIONS_PLIST"
plutil -insert signingCertificate -string "$SIGNING_IDENTITY" "$EXPORT_OPTIONS_PLIST"
plutil -insert signingStyle -string automatic "$EXPORT_OPTIONS_PLIST"
plutil -insert stripSwiftSymbols -bool true "$EXPORT_OPTIONS_PLIST"
plutil -insert teamID -string "$DEVELOPMENT_TEAM" "$EXPORT_OPTIONS_PLIST"

echo "==> Archiving Xcode-provisioned Developer ID app"
xcodebuild archive \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  ARCHS="${ARCHITECTURES[*]}" \
  ONLY_ACTIVE_ARCH=NO \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  ENABLE_HARDENED_RUNTIME=YES

echo "==> Exporting Developer ID app"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
  -allowProvisioningUpdates

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: expected exported app was not created at $APP_PATH" >&2
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

APP_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")"
HELPER_VERSION="$(plutil -extract CFBundleShortVersionString raw "$HELPER_PATH/Contents/Info.plist")"
EXTENSION_VERSION="$(plutil -extract CFBundleShortVersionString raw "$EXTENSION_PATH/Contents/Info.plist")"

if [[ "$APP_VERSION" != "$HELPER_VERSION" || "$APP_VERSION" != "$EXTENSION_VERSION" ]]; then
  echo "error: main app, Helper, and Finder Extension versions must match" >&2
  exit 1
fi

echo "==> Verifying identities, entitlements, profiles, and architectures"
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
  if ! grep -q '^Authority=Developer ID Application:' <<<"$signature_details"; then
    echo "error: $actual_bundle_id is not signed with Developer ID Application" >&2
    exit 1
  fi
  if ! grep -Eq '^Runtime Version=|flags=.*runtime' <<<"$signature_details"; then
    echo "error: hardened runtime is not enabled: $actual_bundle_id" >&2
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
      echo "error: $actual_bundle_id is missing an embedded Developer ID provisioning profile" >&2
      exit 1
    fi

    profile_plist="$BUILD_DIR/provisioning-profile-$index.plist"
    security cms -D -i "$provisioning_profile" >"$profile_plist"
    provisioned_application_identifier="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$profile_plist" 2>/dev/null || true)"
    provisioned_app_group="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.security.application-groups:0' "$profile_plist" 2>/dev/null || true)"
    if [[ "$provisioned_application_identifier" != "$expected_application_identifier" ]]; then
      echo "error: $actual_bundle_id provisioning profile does not authorize $expected_application_identifier" >&2
      exit 1
    fi
    if [[ "$provisioned_app_group" != "group.com.zxacn" ]]; then
      echo "error: $actual_bundle_id provisioning profile does not authorize group.com.zxacn" >&2
      exit 1
    fi
  fi
done

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> Preparing DMG"
ditto "$APP_PATH" "$PACKAGED_APP"
ln -s /Applications "$DMG_ROOT/Applications"

DMG_PATH="$OUTPUT_DIR/ClickMate-$APP_VERSION-universal-signed.dmg"
echo "==> Creating signed DMG"
hdiutil create \
  -volname "ClickMate" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$DMG_PATH"
codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG_PATH"

echo "==> Submitting DMG for notarization"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type install --verbose=2 "$DMG_PATH"

echo
echo "Created: $DMG_PATH"
echo "Team ID: $DEVELOPMENT_TEAM"
