#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
BUILD="$ROOT/build"
STAGE="$(mktemp -d /tmp/OpenNotch-build.XXXXXX)"
APP="$STAGE/Open Notch.app"
OUTPUT_APP="$BUILD/Open Notch.app"
OUTPUT_ZIP="$BUILD/Open Notch.zip"
OUTPUT_DMG="$BUILD/Open Notch 0.8.1.dmg"
ICONSET="$STAGE/AppIcon.iconset"
BASE_ICON="$STAGE/AppIcon-1024.png"
trap 'rm -rf "$STAGE"' EXIT

DMG_STAGE="$STAGE/dmg"
rm -rf "$OUTPUT_APP" "$OUTPUT_ZIP" "$OUTPUT_DMG" "$DMG_STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ICONSET"

swift "$ROOT/Tools/make_icon.swift" "$BASE_ICON"

typeset -a icon_specs=(
  "16 icon_16x16.png"
  "32 icon_16x16@2x.png"
  "32 icon_32x32.png"
  "64 icon_32x32@2x.png"
  "128 icon_128x128.png"
  "256 icon_128x128@2x.png"
  "256 icon_256x256.png"
  "512 icon_256x256@2x.png"
  "512 icon_512x512.png"
  "1024 icon_512x512@2x.png"
)

for spec in "${icon_specs[@]}"; do
  dimension="${spec%% *}"
  filename="${spec#* }"
  sips -z "$dimension" "$dimension" "$BASE_ICON" --out "$ICONSET/$filename" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$STAGE/AppIcon.icns"

swiftc \
  -O \
  -whole-module-optimization \
  -swift-version 5 \
  -target arm64-apple-macos14.0 \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Combine \
  -framework CoreGraphics \
  -framework ServiceManagement \
  -framework SwiftUI \
  "$ROOT"/Sources/*.swift \
  -o "$APP/Contents/MacOS/OpenNotch"

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$STAGE/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
cp "$ROOT/NOTICE.md" "$APP/Contents/Resources/NOTICE.md"
for localization in "$ROOT"/Resources/*.lproj; do
  cp -R "$localization" "$APP/Contents/Resources/"
done
xattr -cr "$APP"
codesign \
  --force \
  --deep \
  --sign - \
  --identifier com.openbartender.OpenNotch \
  --requirements '=designated => identifier "com.openbartender.OpenNotch"' \
  "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$STAGE/Open Notch.zip"
ditto --norsrc --noextattr "$APP" "$OUTPUT_APP"
ditto --norsrc --noextattr "$STAGE/Open Notch.zip" "$OUTPUT_ZIP"
# Finder/File Provider can attach metadata to a copied bundle after the
# staging signature step. Remove it from distributable artifacts so strict
# code-signature verification also succeeds after unzipping the archive.
xattr -r -c "$OUTPUT_APP" 2>/dev/null || true
xattr -c "$OUTPUT_ZIP" 2>/dev/null || true

mkdir -p "$DMG_STAGE"
ditto --norsrc --noextattr "$APP" "$DMG_STAGE/Open Notch.app"
ln -s /Applications "$DMG_STAGE/Applications"
diskutil image create from --volumeName "Open Notch" --format UDZO "$DMG_STAGE" "$OUTPUT_DMG" >/dev/null

echo "$OUTPUT_APP"
