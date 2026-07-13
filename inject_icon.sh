#!/bin/bash

if [ -z "$1" ]; then
    echo "Usage: ./inject_icon.sh <path_to_image>"
    exit 1
fi

LOGO_SOURCE="$1"
ICONSET_DIR="AppIcon.iconset"
APP_PATH=".build/release/BepisLoader.app"

# 1. Create iconset directory
mkdir -p "$ICONSET_DIR"

# 2. Generate icons of different sizes
sips -z 16 16     -s format png "$LOGO_SOURCE" --out "$ICONSET_DIR/icon_16x16.png"
sips -z 32 32     -s format png "$LOGO_SOURCE" --out "$ICONSET_DIR/icon_16x16@2x.png"
sips -z 32 32     -s format png "$LOGO_SOURCE" --out "$ICONSET_DIR/icon_32x32.png"
sips -z 64 64     -s format png "$LOGO_SOURCE" --out "$ICONSET_DIR/icon_32x32@2x.png"
sips -z 128 128   -s format png "$LOGO_SOURCE" --out "$ICONSET_DIR/icon_128x128.png"
sips -z 256 256   -s format png "$LOGO_SOURCE" --out "$ICONSET_DIR/icon_128x128@2x.png"
sips -z 256 256   -s format png "$LOGO_SOURCE" --out "$ICONSET_DIR/icon_256x256.png"
sips -z 512 512   -s format png "$LOGO_SOURCE" --out "$ICONSET_DIR/icon_256x256@2x.png"
sips -z 512 512   -s format png "$LOGO_SOURCE" --out "$ICONSET_DIR/icon_512x512.png"
sips -z 1024 1024 -s format png "$LOGO_SOURCE" --out "$ICONSET_DIR/icon_512x512@2x.png"

# 3. Convert iconset to icns
iconutil -c icns "$ICONSET_DIR"

# 4. Copy to App Bundle
mkdir -p "$APP_PATH/Contents/Resources"
cp AppIcon.icns "$APP_PATH/Contents/Resources/"

# 5. Update Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon.icns" "$APP_PATH/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon.icns" "$APP_PATH/Contents/Info.plist"

# 6. Also update the copy in Downloads
cp -R "$APP_PATH" /Users/parthasarathi/Downloads/

# 7. Cleanup
rm -rf "$ICONSET_DIR"
rm AppIcon.icns

echo "Icon injected successfully!"
