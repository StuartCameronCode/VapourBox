#!/bin/bash
# codesign-dependencies.sh
# Signs all bundled binaries for macOS distribution
#
# Usage: ./codesign-dependencies.sh "Developer ID Application: Your Name (TEAMID)"

set -e

if [ -z "$1" ]; then
    echo "Usage: $0 \"Developer ID Application: Your Name (TEAMID)\""
    echo ""
    echo "For development/testing without signing:"
    echo "  $0 \"-\""
    exit 1
fi

IDENTITY="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_PATH="${2:-$PROJECT_DIR/build/Release/iDeinterlace.app}"

echo "=== Code Signing Dependencies ==="
echo "Identity: $IDENTITY"
echo "App path: $APP_PATH"

if [ ! -d "$APP_PATH" ]; then
    echo "Error: App not found at $APP_PATH"
    echo "Build the app first with: xcodebuild -scheme iDeinterlace -configuration Release"
    exit 1
fi

# Sign VapourSynth plugins
echo ""
echo "Signing VapourSynth plugins..."
find "$APP_PATH/Contents/PlugIns/VapourSynth" -name "*.dylib" 2>/dev/null | while read dylib; do
    echo "  Signing: $(basename "$dylib")"
    codesign --force --sign "$IDENTITY" --timestamp "$dylib"
done

# Sign helper executables
echo ""
echo "Signing helper executables..."
if [ -f "$APP_PATH/Contents/Helpers/vspipe" ]; then
    echo "  Signing: vspipe"
    codesign --force --sign "$IDENTITY" --timestamp "$APP_PATH/Contents/Helpers/vspipe"
fi

if [ -f "$APP_PATH/Contents/Helpers/ffmpeg" ]; then
    echo "  Signing: ffmpeg"
    codesign --force --sign "$IDENTITY" --timestamp "$APP_PATH/Contents/Helpers/ffmpeg"
fi

if [ -f "$APP_PATH/Contents/Helpers/ffprobe" ]; then
    echo "  Signing: ffprobe"
    codesign --force --sign "$IDENTITY" --timestamp "$APP_PATH/Contents/Helpers/ffprobe"
fi

# Sign Python framework
echo ""
echo "Signing Python framework..."
if [ -d "$APP_PATH/Contents/Frameworks/Python.framework" ]; then
    codesign --force --deep --sign "$IDENTITY" --timestamp "$APP_PATH/Contents/Frameworks/Python.framework"
fi

# Sign the worker executable
echo ""
echo "Signing worker executable..."
if [ -f "$APP_PATH/Contents/MacOS/iDeinterlaceWorker" ]; then
    codesign --force --sign "$IDENTITY" --timestamp \
        --entitlements "$PROJECT_DIR/iDeinterlaceWorker/iDeinterlaceWorker.entitlements" \
        "$APP_PATH/Contents/MacOS/iDeinterlaceWorker"
fi

# Sign the main app
echo ""
echo "Signing main application..."
codesign --force --sign "$IDENTITY" --timestamp \
    --entitlements "$PROJECT_DIR/iDeinterlace/Resources/iDeinterlace.entitlements" \
    "$APP_PATH"

# Verify
echo ""
echo "Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo ""
echo "=== Signing Complete ==="
echo "App signed successfully: $APP_PATH"
