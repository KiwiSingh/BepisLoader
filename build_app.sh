#!/bin/bash

# 1. Build the release binary
swift build -c release

# 2. Setup the .app structure
APP_NAME="BepisLoader"
BUNDLE_DIR=".build/release/${APP_NAME}.app"
MACOS_DIR="${BUNDLE_DIR}/Contents/MacOS"
RESOURCES_DIR="${BUNDLE_DIR}/Contents/Resources"

mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

# 3. Copy the binary
cp ".build/release/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"

# 4. Create Info.plist
cat > "${BUNDLE_DIR}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.bepis.loader</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "Successfully built ${APP_NAME}.app in .build/release/"
