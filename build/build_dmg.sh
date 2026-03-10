#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$SCRIPT_DIR"
DMG_PATH="$BUILD_DIR/MyGhost.dmg"
DMG_DIR="$BUILD_DIR/dmg"

# Detect build mode: zig or xcode
BUILD_MODE="${1:-xcode}"

echo "==> Building MyGhost ($BUILD_MODE)..."
cd "$PROJECT_DIR"

if [ "$BUILD_MODE" = "zig" ]; then
    zig build -Doptimize=ReleaseFast 2>&1 | tail -5
    APP_SRC="zig-out/my_ghost.app"
else
    xcodebuild -project macos/Ghostty.xcodeproj -scheme my_ghost -configuration Release build 2>&1 | tail -5
    APP_SRC="$(xcodebuild -project macos/Ghostty.xcodeproj -scheme my_ghost -configuration Release -showBuildSettings 2>/dev/null | grep '^\s*TARGET_BUILD_DIR' | awk '{print $3}')/my_ghost.app"
fi

echo "==> App at: $APP_SRC"

echo "==> Replacing app icon with MyGhost icon..."
# Build a proper icns from the source PNGs
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
iconutil -c icns "$ICONSET_DIR" -o "$APP_SRC/Contents/Resources/Ghostty.icns"

echo "==> Preparing DMG contents..."
rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"
cp -R "$APP_SRC" "$DMG_DIR/MyGhost.app"

echo "==> Cleaning extended attributes..."
xattr -cr "$DMG_DIR/MyGhost.app"

echo "==> Re-signing app..."
codesign --deep --force --sign - "$DMG_DIR/MyGhost.app"

# Set custom icon on the app bundle directly (Finder uses this)
# Must be AFTER codesign and xattr -cr since those clear custom icon metadata
echo "==> Setting Finder custom icon..."
swift -e "
import AppKit
let icon = NSImage(contentsOfFile: \"$PROJECT_DIR/macos/mg_icon_1024.png\")!
NSWorkspace.shared.setIcon(icon, forFile: \"$DMG_DIR/MyGhost.app\", options: [])
print(\"Custom icon set on app bundle\")
"

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
  ln -sf /Applications "$DMG_DIR/Applications"
  hdiutil create -volname "MyGhost" -srcfolder "$DMG_DIR" -ov -format UDZO "$DMG_PATH"
fi

echo "==> Cleaning up..."
rm -rf "$DMG_DIR"

echo ""
echo "Done! DMG saved to: $DMG_PATH"
ls -lh "$DMG_PATH"
