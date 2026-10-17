#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFIER="$ROOT_DIR/Scripts/verify_signing_identity.py"
SOURCE_APP="${1:-$ROOT_DIR/build/development/DerivedData/Build/Products/Release/ClickMate.app}"
DESTINATION=/Applications/ClickMate.app
DRY_RUN="${2:-}"
if [[ $# -gt 2 || ( -n "$DRY_RUN" && "$DRY_RUN" != --dry-run ) ]]; then
  echo "Usage: $0 [path/to/ClickMate.app] [--dry-run]" >&2
  exit 1
fi
/usr/bin/python3 "$VERIFIER" verify "$SOURCE_APP" --kind 'Apple Development'
if [[ -d "$DESTINATION" ]]; then
  SIGNATURE="$(codesign -dv --verbose=4 "$DESTINATION" 2>&1)"
  if [[ "$SIGNATURE" == *'Signature=adhoc'* ]]; then
    echo "Migrating the installed ad-hoc app to a stable development identity."
    echo "Existing TCC grants may belong to the old identity: remove and re-add the installed app in Privacy & Security once after migration."
    echo "This installer does not reset or edit TCC permissions."
  else
    /usr/bin/python3 "$VERIFIER" compare "$DESTINATION" "$SOURCE_APP"
  fi
fi
if [[ "$DRY_RUN" == --dry-run ]]; then
  echo "Preflight passed. No files, processes, accounts or permissions were changed."
  exit 0
fi
# A running Helper or Finder extension can retain the old executable and permissions.
/usr/bin/python3 - "$DESTINATION" <<'PY'
from pathlib import Path
import subprocess
import sys
prefix = str(Path(sys.argv[1]).resolve()) + "/Contents/"
running = []
for line in subprocess.check_output(["/bin/ps", "-axo", "pid=,comm="], text=True).splitlines():
    parts = line.strip().split(None, 1)
    if len(parts) == 2 and parts[1].startswith(prefix):
        running.append(parts[0] + " " + parts[1])
if running:
    sys.exit("error: Quit ClickMate and stop its Background Service and Finder extension before replacement; old processes are still running:\n" + "\n".join(running))
PY
STAGING="$(mktemp -d /Applications/.ClickMate-install.XXXXXX)"
BACKUP=""
REPLACED=0
INSTALL_SUCCEEDED=0
cleanup() {
  if [[ "$INSTALL_SUCCEEDED" == 0 ]]; then
    if [[ "$REPLACED" == 1 && -e "$DESTINATION" ]]; then
      mv "$DESTINATION" "$STAGING/failed-candidate.app"
    fi
    if [[ -n "$BACKUP" && ! -e "$DESTINATION" && -e "$BACKUP" ]]; then
      mv "$BACKUP" "$DESTINATION"
    fi
  fi
  rm -rf "$STAGING"
}
trap cleanup EXIT
ditto "$SOURCE_APP" "$STAGING/ClickMate.app"
/usr/bin/python3 "$VERIFIER" verify "$STAGING/ClickMate.app" --kind 'Apple Development'
if [[ -e "$DESTINATION" ]]; then
  BACKUP="${STAGING}.previous.backup"
  mv "$DESTINATION" "$BACKUP"
fi
mv "$STAGING/ClickMate.app" "$DESTINATION"
REPLACED=1
/usr/bin/python3 "$VERIFIER" verify "$DESTINATION" --kind 'Apple Development'
INSTALL_SUCCEEDED=1
echo "Installed stable development build at $DESTINATION"
if [[ -n "$BACKUP" ]]; then
  echo "Previous bundle retained at $BACKUP"
fi
echo "Open the installed app to register its current Finder extension and Background Service."
