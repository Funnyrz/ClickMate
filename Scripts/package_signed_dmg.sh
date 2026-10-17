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
IDENTITY_VERIFIER="$ROOT_DIR/Scripts/verify_signing_identity.py"
PREVIOUS_APP="${CLICKMATE_PREVIOUS_APP:-}"

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

BASELINE_DIR=""
trap '[[ -z "$BASELINE_DIR" ]] || rm -rf "$BASELINE_DIR"' EXIT
if [[ -n "$PREVIOUS_APP" ]]; then
  /usr/bin/python3 "$IDENTITY_VERIFIER" identity-check "$PREVIOUS_APP" --team "$DEVELOPMENT_TEAM" --kind 'Developer ID Application'
elif [[ -d "$APP_PATH" ]] && /usr/bin/python3 "$IDENTITY_VERIFIER" identity-check "$APP_PATH" --team "$DEVELOPMENT_TEAM" --kind 'Developer ID Application' >/dev/null 2>&1; then
  PREVIOUS_APP="$APP_PATH"
elif [[ -d /Applications/ClickMate.app ]] && /usr/bin/python3 "$IDENTITY_VERIFIER" identity-check /Applications/ClickMate.app --team "$DEVELOPMENT_TEAM" --kind 'Developer ID Application' >/dev/null 2>&1; then
  PREVIOUS_APP=/Applications/ClickMate.app
fi
if [[ -n "$PREVIOUS_APP" ]]; then
  BASELINE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clickmate-signing-baseline.XXXXXX")"
  ditto "$PREVIOUS_APP" "$BASELINE_DIR/ClickMate.app"
  PREVIOUS_APP="$BASELINE_DIR/ClickMate.app"
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
  ENABLE_CODE_COVERAGE=NO \
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
APP_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")"
echo "==> Verifying Universal 2 architectures and release instrumentation"
for bundle in "${BUNDLES[@]}"; do
  executable_name="$(plutil -extract CFBundleExecutable raw "$bundle/Contents/Info.plist")"
  executable="$bundle/Contents/MacOS/$executable_name"
  for architecture in "${ARCHITECTURES[@]}"; do
    lipo "$executable" -verify_arch "$architecture"
  done
  if otool -l "$executable" | grep -q '__LLVM_COV'; then
    echo "error: release executable contains code coverage instrumentation: $executable" >&2
    exit 1
  fi
done
/usr/bin/python3 "$IDENTITY_VERIFIER" verify "$APP_PATH" --team "$DEVELOPMENT_TEAM" --kind 'Developer ID Application'
if [[ -n "$PREVIOUS_APP" ]]; then
  /usr/bin/python3 "$IDENTITY_VERIFIER" compare "$PREVIOUS_APP" "$APP_PATH"
fi
if [[ -n "${CLICKMATE_IDENTITY_COMPARISON_APP:-}" ]]; then
  /usr/bin/python3 "$IDENTITY_VERIFIER" compare "$CLICKMATE_IDENTITY_COMPARISON_APP" "$APP_PATH" --require-code-change
fi

echo "==> Preparing DMG"
ditto "$APP_PATH" "$PACKAGED_APP"
/usr/bin/python3 "$IDENTITY_VERIFIER" verify "$PACKAGED_APP" --team "$DEVELOPMENT_TEAM" --kind 'Developer ID Application'
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
