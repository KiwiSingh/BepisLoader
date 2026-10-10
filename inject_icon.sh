#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
LOGO_SOURCE="${1:-$ROOT/BepisLogo.png}"
APP_PATH="${2:-$ROOT/.build/release/BepisLoader.app}"
if [ ! -f "$LOGO_SOURCE" ] || [ ! -f "$APP_PATH/Contents/Info.plist" ]; then
    echo "Usage: inject_icon.sh <image> [existing app bundle]" >&2
    exit 1
fi
# Keep every generated file beside this checkout; never copy to Downloads.
mkdir -p "$ROOT/.build/icon-work"
WORK_DIR="$(mktemp -d "$ROOT/.build/icon-work/inject.XXXXXX")"
ICONSET_DIR="$WORK_DIR/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" -s format png "$LOGO_SOURCE" --out "$ICONSET_DIR/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" -s format png "$LOGO_SOURCE" --out "$ICONSET_DIR/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET_DIR" -o "$WORK_DIR/AppIcon.icns"
mkdir -p "$APP_PATH/Contents/Resources"
cp "$WORK_DIR/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon.icns" "$APP_PATH/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon.icns" "$APP_PATH/Contents/Info.plist"
echo "Icon injected into $APP_PATH"
