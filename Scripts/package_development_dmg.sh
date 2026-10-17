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

IDENTITY_VERIFIER="$ROOT_DIR/Scripts/verify_signing_identity.py"
IDENTITY_ARGS=()
if [[ -n "${CLICKMATE_DEVELOPMENT_IDENTITY:-}" ]]; then
  IDENTITY_ARGS+=(--identity "$CLICKMATE_DEVELOPMENT_IDENTITY")
fi
if [[ -n "${CLICKMATE_DEVELOPMENT_TEAM:-}" ]]; then
  IDENTITY_ARGS+=(--team "$CLICKMATE_DEVELOPMENT_TEAM")
fi
IDENTITY_DETAILS="$(/usr/bin/python3 "$IDENTITY_VERIFIER" identity ${IDENTITY_ARGS[@]+"${IDENTITY_ARGS[@]}"})"
IFS=$'\t' read -r SIGNING_IDENTITY DEVELOPMENT_TEAM SIGNING_NAME <<<"$IDENTITY_DETAILS"
echo "==> Using $SIGNING_NAME, certificate Team ID $DEVELOPMENT_TEAM"
PROVISIONING_ARGS=()
if [[ "${CLICKMATE_ALLOW_PROVISIONING_UPDATES:-0}" == "1" ]]; then
  PROVISIONING_ARGS=(-allowProvisioningUpdates)
else
  /usr/bin/python3 "$IDENTITY_VERIFIER" profiles --team "$DEVELOPMENT_TEAM" --certificate "$SIGNING_IDENTITY"
fi

# Preserve a previously verified build before the clean build removes its directory.
PREVIOUS_APP="${CLICKMATE_PREVIOUS_APP:-}"
BASELINE_DIR=""
trap '[[ -z "$BASELINE_DIR" ]] || rm -rf "$BASELINE_DIR"' EXIT
if [[ -n "$PREVIOUS_APP" ]]; then
  /usr/bin/python3 "$IDENTITY_VERIFIER" identity-check "$PREVIOUS_APP" --team "$DEVELOPMENT_TEAM" --kind 'Apple Development'
elif [[ -d "$APP_PATH" ]] && /usr/bin/python3 "$IDENTITY_VERIFIER" identity-check "$APP_PATH" --team "$DEVELOPMENT_TEAM" --kind 'Apple Development' >/dev/null 2>&1; then
  PREVIOUS_APP="$APP_PATH"
elif [[ -d /Applications/ClickMate.app ]] && /usr/bin/python3 "$IDENTITY_VERIFIER" identity-check /Applications/ClickMate.app --team "$DEVELOPMENT_TEAM" --kind 'Apple Development' >/dev/null 2>&1; then
  PREVIOUS_APP=/Applications/ClickMate.app
fi
if [[ -n "$PREVIOUS_APP" ]]; then
  BASELINE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clickmate-signing-baseline.XXXXXX")"
  ditto "$PREVIOUS_APP" "$BASELINE_DIR/ClickMate.app"
  PREVIOUS_APP="$BASELINE_DIR/ClickMate.app"
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
  ${PROVISIONING_ARGS[@]+"${PROVISIONING_ARGS[@]}"} \
  ARCHS="${ARCHITECTURES[*]}" \
  ONLY_ACTIVE_ARCH=NO \
  ENABLE_CODE_COVERAGE=NO \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="Apple Development" \
  ENABLE_HARDENED_RUNTIME=YES

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: expected app was not created at $APP_PATH" >&2
  exit 1
fi

HELPER_PATH="$APP_PATH/Contents/Library/LoginItems/ClickMateHelper.app"
EXTENSION_PATH="$APP_PATH/Contents/PlugIns/ClickMateFinderExtension.appex"

BUNDLES=("$APP_PATH" "$HELPER_PATH" "$EXTENSION_PATH")
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
/usr/bin/python3 "$IDENTITY_VERIFIER" verify "$APP_PATH" --team "$DEVELOPMENT_TEAM" --kind 'Apple Development' --certificate "$SIGNING_IDENTITY"
if [[ -n "$PREVIOUS_APP" ]]; then
  /usr/bin/python3 "$IDENTITY_VERIFIER" compare "$PREVIOUS_APP" "$APP_PATH"
else
  echo "No valid previous development build found; this is the signing baseline."
fi
if [[ -n "${CLICKMATE_IDENTITY_COMPARISON_APP:-}" ]]; then
  /usr/bin/python3 "$IDENTITY_VERIFIER" compare "$CLICKMATE_IDENTITY_COMPARISON_APP" "$APP_PATH" --require-code-change
fi

APP_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")"
BUILD_VERSION="$(plutil -extract CFBundleVersion raw "$APP_PATH/Contents/Info.plist")"
DMG_PATH="$OUTPUT_DIR/ClickMate-$APP_VERSION-$BUILD_VERSION-development.dmg"

echo "==> Preparing DMG"
ditto "$APP_PATH" "$PACKAGED_APP"
/usr/bin/python3 "$IDENTITY_VERIFIER" verify "$PACKAGED_APP" --team "$DEVELOPMENT_TEAM" --kind 'Apple Development' --certificate "$SIGNING_IDENTITY"
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
