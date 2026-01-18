#!/bin/bash
# Package VapourBox for macOS
# Creates a lightweight .app bundle - dependencies are downloaded on first run
#
# Prerequisites:
# - Flutter SDK installed
# - Rust toolchain installed
# - Xcode Command Line Tools
#
# Usage: ./Scripts/package-macos.sh [--skip-build] [--version X.Y.Z] [--arch arm64|x64]

set -e

VERSION="1.0.0"
SKIP_BUILD=false
ARCH=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --version)
            VERSION="$2"
            shift 2
            ;;
        --arch)
            ARCH="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Detect architecture if not specified
if [ -z "$ARCH" ]; then
    if [ "$(uname -m)" = "arm64" ]; then
        ARCH="arm64"
    else
        ARCH="x64"
    fi
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_ROOT/dist"
APP_NAME="VapourBox"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

echo "=== Packaging VapourBox for macOS ($ARCH) ==="
echo ""

# Build Rust worker
if [ "$SKIP_BUILD" = false ]; then
    echo "[1/5] Building Rust worker..."
    cd "$PROJECT_ROOT/worker"
    if [ "$ARCH" = "arm64" ]; then
        cargo build --release --target aarch64-apple-darwin
        WORKER_BIN="$PROJECT_ROOT/worker/target/aarch64-apple-darwin/release/vapourbox-worker"
    else
        cargo build --release --target x86_64-apple-darwin
        WORKER_BIN="$PROJECT_ROOT/worker/target/x86_64-apple-darwin/release/vapourbox-worker"
    fi
    # Fallback to default target if specific target not found
    if [ ! -f "$WORKER_BIN" ]; then
        cargo build --release
        WORKER_BIN="$PROJECT_ROOT/worker/target/release/vapourbox-worker"
    fi
    echo "    Rust worker built"

    # Build Flutter app
    echo "[2/5] Building Flutter app..."
    cd "$PROJECT_ROOT/app"
    flutter pub get
    flutter build macos --release
    echo "    Flutter app built"
else
    echo "[1/5] Skipping Rust build (--skip-build)"
    echo "[2/5] Skipping Flutter build (--skip-build)"
    WORKER_BIN="$PROJECT_ROOT/worker/target/release/vapourbox-worker"
fi

# Create app bundle structure
echo "[3/5] Creating app bundle structure..."
rm -rf "$APP_BUNDLE"
mkdir -p "$DIST_DIR"

# Copy Flutter app bundle as base
FLUTTER_APP="$PROJECT_ROOT/app/build/macos/Build/Products/Release/vapourbox.app"
if [ ! -d "$FLUTTER_APP" ]; then
    echo "ERROR: Flutter app bundle not found at $FLUTTER_APP"
    exit 1
fi
cp -R "$FLUTTER_APP" "$APP_BUNDLE"

# Create additional directories
CONTENTS="$APP_BUNDLE/Contents"
mkdir -p "$CONTENTS/MacOS/templates"
mkdir -p "$CONTENTS/Resources/licenses"

# Copy Rust worker
echo "[4/5] Copying Rust worker and templates..."
if [ ! -f "$WORKER_BIN" ]; then
    echo "ERROR: Worker executable not found at $WORKER_BIN"
    exit 1
fi
cp "$WORKER_BIN" "$CONTENTS/MacOS/vapourbox-worker"
chmod +x "$CONTENTS/MacOS/vapourbox-worker"

# Copy VapourSynth script templates
cp "$PROJECT_ROOT/worker/templates/qtgmc_template.vpy" "$CONTENTS/MacOS/templates/"
cp "$PROJECT_ROOT/worker/templates/pipeline_template.vpy" "$CONTENTS/MacOS/templates/"
cp "$PROJECT_ROOT/worker/templates/preview_template.vpy" "$CONTENTS/MacOS/templates/"

# Copy licenses
cp -r "$PROJECT_ROOT/licenses/"* "$CONTENTS/Resources/licenses/"
cp "$PROJECT_ROOT/LICENSE" "$CONTENTS/Resources/LICENSE"

# Update Info.plist with version
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$CONTENTS/Info.plist" 2>/dev/null || true

# Sign binaries
echo "[5/5] Signing app bundle..."
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true

# Calculate size
APP_SIZE=$(du -sh "$APP_BUNDLE" | cut -f1)

echo ""
echo "=== Packaging Complete ==="
echo ""
echo "App bundle created: $APP_BUNDLE"
echo "Bundle size: $APP_SIZE"
echo ""
echo "Note: Dependencies (~94 MB) will be downloaded on first run."
echo ""

# Create zip archive
ZIP_FILE="$DIST_DIR/$APP_NAME-$VERSION-macos-$ARCH.zip"
echo "Creating zip archive..."
cd "$DIST_DIR"
rm -f "$ZIP_FILE"
zip -r -q "$ZIP_FILE" "$APP_NAME.app"
ZIP_SIZE=$(du -sh "$ZIP_FILE" | cut -f1)
echo "Zip file: $ZIP_FILE ($ZIP_SIZE)"
echo ""

echo "To install:"
echo "  cp -R '$APP_BUNDLE' /Applications/"
echo ""
echo "To distribute, share the zip file:"
echo "  $ZIP_FILE"
