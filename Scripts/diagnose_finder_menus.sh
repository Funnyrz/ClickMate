#!/bin/bash
# Read-only diagnostics. Does not change extension registration, permissions, or settings.
set -euo pipefail

APP_PATH="${1:-/Applications/ClickMate.app}"
EXTENSION_PATH="$APP_PATH/Contents/PlugIns/ClickMateFinderExtension.appex"
EXTENSION_ID="com.zxacn.clickmate.FinderExtension"

section() { printf '\n%s\n' "$1"; }

section "System"
/usr/bin/sw_vers
/usr/bin/uname -m

section "Installed application and extension"
for bundle in "$APP_PATH" "$EXTENSION_PATH"; do
    printf '\nBundle: %s\n' "$bundle"
    if [[ ! -d "$bundle" ]]; then
        printf 'Bundle is missing\n'
        continue
    fi
    for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion; do
        printf '%s: ' "$key"
        /usr/bin/plutil -extract "$key" raw "$bundle/Contents/Info.plist" || true
        printf '\n'
    done
    if executable="$(/usr/bin/plutil -extract CFBundleExecutable raw "$bundle/Contents/Info.plist")"; then
        /usr/bin/shasum -a 256 "$bundle/Contents/MacOS/$executable" || true
    fi
    /usr/bin/codesign -d --verbose=4 "$bundle" 2>&1 || true
done

section "All registrations of ClickMate Finder Extension"
/usr/bin/pluginkit -m -A -D -v -i "$EXTENSION_ID" 2>&1 || true

section "Other Finder Sync extensions (registration alone does not prove a conflict)"
/usr/bin/pluginkit -m -A -D -v -p com.apple.FinderSync 2>&1 || true

section "Running ClickMate components"
/bin/ps -axo pid=,comm= | /usr/bin/awk '/\/(ClickMate|ClickMateHelper|ClickMateFinderExtension)$/ {print}'

section "Default folder locations (metadata only, no directory contents)"
for name in Desktop Documents Downloads Movies Music Pictures Public Projects Workspace; do
    folder="$HOME/$name"
    printf '\nFolder: %s\n' "$folder"
    /bin/ls -ld "$folder" 2>&1 || true
    # Resolving the physical location reveals redirected folders. Failure here
    # is diagnostic only; it must never decide Finder monitoring coverage.
    if physical="$(cd "$folder" 2>/dev/null && /bin/pwd -P)"; then
        printf 'Physical location: %s\n' "$physical"
    else
        printf 'Physical location could not be resolved by this terminal\n'
    fi
done

section "Recent Finder extension events"
# Excludes URLRouter/file-operation logs, which can contain selected filenames.
# Older builds may have only root counts; absence of events is inconclusive.
/usr/bin/log show --last 5m --style compact --info --debug \
    --predicate 'subsystem == "com.zxacn.clickmate" AND category == "FinderSync"' \
    2>&1 | /usr/bin/tail -n 200 || true

section "Interpretation"
printf '%s\n' \
    'Music-only menus do not establish a Full Disk Access failure.' \
    'Compare executable hashes and installed paths with the supplied DMG.' \
    'Monitoring policy 5 or later keeps default roots even if directory discovery fails.' \
    'Enabled registration does not establish runtime coverage of any folder.' \
    'A redirected folder or another enabled extension is a clue, not proof of the cause.' \
    'This report contains local installation and folder paths; review it before sharing.'
