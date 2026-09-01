#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
BUILD="$ROOT/build"
ZIP="$BUILD/OPEN-BAR-1.0.0-beta.zip"
SCRATCH="${TMPDIR:-/tmp}/openbar-swiftpm-${UID}"
STAGE="$(mktemp -d /tmp/OpenBar-release.XXXXXX)"
APP="$STAGE/OPEN BAR.app"
STAGED_ZIP="$STAGE/OPEN-BAR-1.0.0-beta.zip"
VERIFY_ROOT="$STAGE/verify"
ICONSET="$STAGE/AppIcon.iconset"
MASTER="$STAGE/AppIcon-1024.png"
SIGN_IDENTITY="${OPEN_BAR_SIGN_IDENTITY:--}"
trap 'rm -rf "$STAGE"' EXIT

if [[ "${OPEN_BAR_DISTRIBUTION:-0}" == "1" && "$SIGN_IDENTITY" == "-" ]]; then
    print -u2 "OPEN_BAR_DISTRIBUTION=1 requires OPEN_BAR_SIGN_IDENTITY (Developer ID Application)."
    exit 2
fi

echo "[1/5] Testing core"
swift run --package-path "$ROOT" --scratch-path "$SCRATCH" OpenBarCoreChecks

echo "[2/5] Building arm64 release binary"
ARCH_SCRATCH="$SCRATCH/arm64"
swift build \
    --package-path "$ROOT" \
    -c release \
    --scratch-path "$ARCH_SCRATCH" \
    --triple arm64-apple-macosx14.0
BIN_DIR="$(swift build \
    --package-path "$ROOT" \
    -c release \
    --scratch-path "$ARCH_SCRATCH" \
    --triple arm64-apple-macosx14.0 \
    --show-bin-path)"

echo "[3/5] Generating app icon"
mkdir -p "$ICONSET"
xcrun swift "$ROOT/Tools/make_icon.swift" "$MASTER"
for spec in '16 icon_16x16.png' '32 icon_16x16@2x.png' '32 icon_32x32.png' \
            '64 icon_32x32@2x.png' '128 icon_128x128.png' '256 icon_128x128@2x.png' \
            '256 icon_256x256.png' '512 icon_256x256@2x.png' '512 icon_512x512.png' \
            '1024 icon_512x512@2x.png'; do
    pixels="${spec%% *}"
    filename="${spec#* }"
    sips -z "$pixels" "$pixels" "$MASTER" --out "$ICONSET/$filename" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$STAGE/AppIcon.icns"

echo "[4/5] Assembling application"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD"
cp -X "$BIN_DIR/OpenBar" "$APP/Contents/MacOS/OpenBar"
cp -X "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp -X "$STAGE/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
for localization in "$ROOT"/Resources/*.lproj; do
    ditto --norsrc --noextattr "$localization" "$APP/Contents/Resources/${localization:t}"
done
plutil -lint "$APP/Contents/Info.plist" >/dev/null
xattr -cr "$APP"
codesign --force --options runtime --sign "$SIGN_IDENTITY" \
    --identifier com.woniuniuniu.OpenBar \
    --requirements '=designated => identifier "com.woniuniuniu.OpenBar"' "$APP"
codesign --verify --deep --strict "$APP"

echo "[5/5] Packaging"
rm -rf "$BUILD/OPEN BAR.app"
rm -f "$ZIP"
ditto -c -k --keepParent --norsrc --noextattr "$APP" "$STAGED_ZIP"
mkdir -p "$VERIFY_ROOT"
ditto -x -k --norsrc --noextattr "$STAGED_ZIP" "$VERIFY_ROOT"
codesign --verify --deep --strict "$VERIFY_ROOT/OPEN BAR.app"
cp -X "$STAGED_ZIP" "$ZIP"

echo "$ZIP"
