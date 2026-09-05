#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
ARCHIVE="$ROOT/build/OPEN-BAR-1.1.0.zip"
INSTALL_ROOT="${OPEN_BAR_INSTALL_DIR:-$HOME/Applications}"
DESTINATION="$INSTALL_ROOT/OPEN BAR.app"
STAGE="$(mktemp -d /tmp/OpenBar-install.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

if [[ ! -f "$ARCHIVE" ]]; then
    "$ROOT/build.sh"
fi

mkdir -p "$INSTALL_ROOT"
ditto -x -k "$ARCHIVE" "$STAGE"
xattr -cr "$STAGE/OPEN BAR.app"
codesign --verify --deep --strict "$STAGE/OPEN BAR.app"

pkill -x OpenBar 2>/dev/null || true
pkill -x OpenNotch 2>/dev/null || true

for OLD_APP in \
    "$DESTINATION" \
    "/Applications/OPEN BAR.app" \
    "$HOME/Applications/Open Notch.app" \
    "/Applications/Open Notch.app"; do
    if [[ -e "$OLD_APP" ]]; then
        /bin/rm -R -- "$OLD_APP"
    fi
done

ditto --norsrc --noextattr "$STAGE/OPEN BAR.app" "$DESTINATION"
xattr -cr "$DESTINATION"
codesign --verify --deep --strict "$DESTINATION"

# Updating the local build terminates the previous instance above. Relaunch the
# newly installed app so its menu-bar control is restored immediately instead
# of silently disappearing until the user opens OPEN BAR again.
if [[ "${OPEN_BAR_LAUNCH:-1}" == "1" ]]; then
    open -- "$DESTINATION"
fi

echo "$DESTINATION"
