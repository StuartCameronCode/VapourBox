#!/bin/bash
# Build a proper macOS .app bundle from Swift Package executables
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_ROOT/.build/release"
APP_NAME="iDeinterlace"
APP_BUNDLE="$PROJECT_ROOT/build/$APP_NAME.app"
BUNDLE_ID="com.stuartcameron.iDeinterlace"

echo "Building Swift Package..."
cd "$PROJECT_ROOT"
swift build -c release

echo "Creating app bundle structure..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Helpers"

echo "Copying executables..."
cp "$BUILD_DIR/iDeinterlace" "$APP_BUNDLE/Contents/MacOS/"
cp "$BUILD_DIR/iDeinterlaceWorker" "$APP_BUNDLE/Contents/Helpers/"

echo "Creating Info.plist..."
cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>iDeinterlace</string>
    <key>CFBundleIdentifier</key>
    <string>com.stuartcameron.iDeinterlace</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>iDeinterlace</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright 2024. All rights reserved.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Video</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.movie</string>
                <string>public.video</string>
                <string>com.apple.quicktime-movie</string>
                <string>public.mpeg-4</string>
                <string>public.avi</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "Creating PkgInfo..."
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo "Signing app bundle..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo ""
echo "App bundle created: $APP_BUNDLE"
echo ""
echo "To run: open '$APP_BUNDLE'"
echo "Or:     '$APP_BUNDLE/Contents/MacOS/iDeinterlace'"
