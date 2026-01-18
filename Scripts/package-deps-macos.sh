#!/bin/bash
# Package VapourBox Dependencies for macOS
# Creates standalone dependency zip files for arm64 and x64
#
# Prerequisites:
# - Dependencies downloaded (run download-deps-macos.sh first)
#
# Usage: ./Scripts/package-deps-macos.sh --version 1.0.0 [--arch arm64|x64|both]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_ROOT/dist"

VERSION=""
ARCH="both"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --version)
            VERSION="$2"
            shift 2
            ;;
        --arch)
            ARCH="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if [ -z "$VERSION" ]; then
    echo "ERROR: --version is required" >&2
    echo "Usage: $0 --version 1.0.0 [--arch arm64|x64|both]" >&2
    exit 1
fi

echo "=== Packaging VapourBox Dependencies for macOS ==="
echo "Version: $VERSION"
echo "Architecture: $ARCH"
echo ""

mkdir -p "$DIST_DIR"

package_arch() {
    local ARCH_NAME=$1
    local DEPS_DIR="$PROJECT_ROOT/deps/macos-$ARCH_NAME"
    local PACKAGE_NAME="VapourBox-deps-$VERSION-macos-$ARCH_NAME"
    local PACKAGE_DIR="$DIST_DIR/$PACKAGE_NAME"

    echo "[1/4] Checking prerequisites for $ARCH_NAME..."

    if [ ! -d "$DEPS_DIR" ]; then
        echo "WARNING: Dependencies not found at $DEPS_DIR"
        echo "Run './Scripts/download-deps-macos.sh --arch $ARCH_NAME' first"
        return 1
    fi

    # Check for required files
    if [ ! -f "$DEPS_DIR/ffmpeg/ffmpeg" ]; then
        echo "WARNING: FFmpeg not found for $ARCH_NAME"
        return 1
    fi

    echo "    Prerequisites OK for $ARCH_NAME"

    echo "[2/4] Creating package structure for $ARCH_NAME..."
    rm -rf "$PACKAGE_DIR"
    mkdir -p "$PACKAGE_DIR/ffmpeg"
    mkdir -p "$PACKAGE_DIR/vapoursynth/plugins"
    mkdir -p "$PACKAGE_DIR/python-packages"

    echo "[3/4] Copying dependencies for $ARCH_NAME..."

    # Copy FFmpeg
    echo "    Copying FFmpeg..."
    cp "$DEPS_DIR/ffmpeg/ffmpeg" "$PACKAGE_DIR/ffmpeg/"
    [ -f "$DEPS_DIR/ffmpeg/ffprobe" ] && cp "$DEPS_DIR/ffmpeg/ffprobe" "$PACKAGE_DIR/ffmpeg/"

    # Copy VapourSynth
    echo "    Copying VapourSynth..."
    if [ -d "$DEPS_DIR/vapoursynth" ]; then
        cp -r "$DEPS_DIR/vapoursynth/"* "$PACKAGE_DIR/vapoursynth/"
    fi

    # Copy plugins
    if [ -d "$DEPS_DIR/vapoursynth/plugins" ]; then
        cp -r "$DEPS_DIR/vapoursynth/plugins/"* "$PACKAGE_DIR/vapoursynth/plugins/" 2>/dev/null || true
    fi

    # Copy Python packages
    echo "    Copying Python packages..."
    if [ -d "$DEPS_DIR/python-packages" ]; then
        cp -r "$DEPS_DIR/python-packages/"* "$PACKAGE_DIR/python-packages/"
    fi

    # Copy NNEDI3 weights if present
    if [ -f "$DEPS_DIR/vapoursynth/nnedi3_weights.bin" ]; then
        cp "$DEPS_DIR/vapoursynth/nnedi3_weights.bin" "$PACKAGE_DIR/vapoursynth/"
    fi

    # Create version file
    echo "    Creating version file..."
    cat > "$PACKAGE_DIR/version.json" << EOF
{
  "version": "$VERSION",
  "installedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

    # Remove unnecessary files
    echo "    Cleaning up..."
    find "$PACKAGE_DIR" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
    find "$PACKAGE_DIR" -name "*.pyc" -delete 2>/dev/null || true
    find "$PACKAGE_DIR" -name ".DS_Store" -delete 2>/dev/null || true
    find "$PACKAGE_DIR" -name "tmpclaude-*" -delete 2>/dev/null || true

    echo "[4/4] Creating zip archive for $ARCH_NAME..."
    local ZIP_FILE="$DIST_DIR/$PACKAGE_NAME.zip"
    rm -f "$ZIP_FILE"
    cd "$DIST_DIR"
    zip -r -q "$PACKAGE_NAME.zip" "$PACKAGE_NAME"

    # Calculate size and hash
    local ZIP_SIZE=$(stat -f%z "$ZIP_FILE" 2>/dev/null || stat -c%s "$ZIP_FILE" 2>/dev/null)
    local ZIP_SIZE_MB=$(echo "scale=1; $ZIP_SIZE / 1048576" | bc)
    local SHA256=$(shasum -a 256 "$ZIP_FILE" | cut -d' ' -f1)

    echo ""
    echo "=== $ARCH_NAME Package Complete ==="
    echo "Zip file: $ZIP_FILE"
    echo "Size: ${ZIP_SIZE_MB} MB"
    echo "SHA256: $SHA256"
    echo ""

    # Cleanup
    rm -rf "$PACKAGE_DIR"

    # Output JSON snippet
    echo "Update deps-version.json with:"
    echo "  \"macos-$ARCH_NAME\": {"
    echo "    \"filename\": \"$PACKAGE_NAME.zip\","
    echo "    \"sha256\": \"$SHA256\","
    echo "    \"size\": $ZIP_SIZE"
    echo "  }"
    echo ""
}

# Package requested architectures
case "$ARCH" in
    arm64)
        package_arch "arm64"
        ;;
    x64)
        package_arch "x64"
        ;;
    both)
        echo "Packaging both architectures..."
        echo ""
        package_arch "arm64" || echo "WARNING: arm64 packaging failed"
        echo ""
        package_arch "x64" || echo "WARNING: x64 packaging failed"
        ;;
    *)
        echo "ERROR: Invalid architecture: $ARCH" >&2
        echo "Use: arm64, x64, or both" >&2
        exit 1
        ;;
esac

echo "Done. Upload zip files to GitHub release deps-v$VERSION"
