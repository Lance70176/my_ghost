#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$SCRIPT_DIR"
APP_NAME="my_ghost.app"
DMG_PATH="$BUILD_DIR/MyGhost.dmg"
DMG_DIR="$BUILD_DIR/dmg"

echo "==> Building MyGhost (ReleaseFast)..."
cd "$PROJECT_DIR"
zig build -Doptimize=ReleaseFast 2>&1 | tail -5

echo "==> Replacing app icon with MyGhost icon..."
cp "$PROJECT_DIR/macos/MyGhost.icns" "zig-out/$APP_NAME/Contents/Resources/Ghostty.icns"

# Also rebuild Assets.car to replace the compiled icon
ICONSET_DIR="/tmp/MyGhost.iconset"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
cp "$PROJECT_DIR/macos/mg_icon_1024.png" "$ICONSET_DIR/icon_512x512@2x.png"
cp "$PROJECT_DIR/macos/mg_icon_512.png" "$ICONSET_DIR/icon_512x512.png"
cp "$PROJECT_DIR/macos/mg_icon_512.png" "$ICONSET_DIR/icon_256x256@2x.png"
cp "$PROJECT_DIR/macos/mg_icon_256.png" "$ICONSET_DIR/icon_256x256.png"
sips -z 128 128 "$PROJECT_DIR/macos/mg_icon_256.png" --out "$ICONSET_DIR/icon_128x128.png" > /dev/null
cp "$PROJECT_DIR/macos/mg_icon_256.png" "$ICONSET_DIR/icon_128x128@2x.png"
sips -z 64 64 "$PROJECT_DIR/macos/mg_icon_256.png" --out "$ICONSET_DIR/icon_32x32@2x.png" > /dev/null
sips -z 32 32 "$PROJECT_DIR/macos/mg_icon_256.png" --out "$ICONSET_DIR/icon_32x32.png" > /dev/null
sips -z 32 32 "$PROJECT_DIR/macos/mg_icon_256.png" --out "$ICONSET_DIR/icon_16x16@2x.png" > /dev/null
sips -z 16 16 "$PROJECT_DIR/macos/mg_icon_256.png" --out "$ICONSET_DIR/icon_16x16.png" > /dev/null
iconutil -c icns "$ICONSET_DIR" -o "zig-out/$APP_NAME/Contents/Resources/Ghostty.icns"

echo "==> Cleaning extended attributes..."
xattr -cr "zig-out/$APP_NAME"

# Set custom icon on the app bundle directly (Finder uses this)
# Must be AFTER xattr -cr since that clears custom icon metadata
swift -e "
import AppKit
let icon = NSImage(contentsOfFile: \"$PROJECT_DIR/macos/mg_icon_1024.png\")!
NSWorkspace.shared.setIcon(icon, forFile: \"$(pwd)/zig-out/$APP_NAME\", options: [])
print(\"Custom icon set on app bundle\")
"

echo "==> Preparing DMG contents..."
rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"
cp -R "zig-out/$APP_NAME" "$DMG_DIR/MyGhost.app"

echo "==> Creating styled DMG..."
rm -f "$DMG_PATH"

if command -v create-dmg &> /dev/null; then
  create-dmg \
    --volname "MyGhost" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 160 \
    --text-size 14 \
    --icon "MyGhost.app" 165 175 \
    --app-drop-link 495 175 \
    --hide-extension "MyGhost.app" \
    --no-internet-enable \
    "$DMG_PATH" \
    "$DMG_DIR"
else
  echo "  (create-dmg not found, using hdiutil fallback)"
  hdiutil create -volname "MyGhost" -srcfolder "$DMG_DIR" -ov -format UDZO "$DMG_PATH"
fi

echo "==> Cleaning up..."
rm -rf "$DMG_DIR"

echo ""
echo "Done! DMG saved to: $DMG_PATH"
