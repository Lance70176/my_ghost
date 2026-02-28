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

echo "==> Cleaning extended attributes..."
xattr -cr "zig-out/$APP_NAME"

echo "==> Preparing DMG contents..."
rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"
cp -R "zig-out/$APP_NAME" "$DMG_DIR/"

echo "==> Creating styled DMG..."
rm -f "$DMG_PATH"

if command -v create-dmg &> /dev/null; then
  create-dmg \
    --volname "MyGhost" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 160 \
    --text-size 14 \
    --icon "$APP_NAME" 165 175 \
    --app-drop-link 495 175 \
    --hide-extension "$APP_NAME" \
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
