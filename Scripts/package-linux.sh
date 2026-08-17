#!/bin/bash
# Package VapourBox for Linux
# Creates a distributable tarball with Flutter app + Rust worker + templates
#
# Prerequisites:
# - Flutter SDK, Rust toolchain
# - Worker and app already built (or use without --skip-build)
#
# Usage: ./Scripts/package-linux.sh --version X.Y.Z [--skip-build] [--arch x64|arm64]

set -e

VERSION="1.0.0"
SKIP_BUILD=false
ARCH=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --version) VERSION="$2"; shift 2 ;;
        --skip-build) SKIP_BUILD=true; shift ;;
        --arch) ARCH="$2"; shift 2 ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 --version X.Y.Z [--skip-build] [--arch x64|arm64]"
            exit 1
            ;;
    esac
done

# Detect architecture if not specified
if [ -z "$ARCH" ]; then
    if [ "$(uname -m)" = "aarch64" ]; then
        ARCH="arm64"
    else
        ARCH="x64"
    fi
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_ROOT/dist"
PACKAGE_NAME="VapourBox-$VERSION-linux-$ARCH"
PACKAGE_DIR="$DIST_DIR/$PACKAGE_NAME"

echo "=== Packaging VapourBox for Linux ($ARCH) ==="
echo "Version: $VERSION"
echo ""

STEP=1
TOTAL_STEPS=4
if ! $SKIP_BUILD; then
    TOTAL_STEPS=5
fi

# Build if needed
if ! $SKIP_BUILD; then
    echo "[$STEP/$TOTAL_STEPS] Building Rust worker..."
    cd "$PROJECT_ROOT/worker"
    cargo build --release
    STEP=$((STEP + 1))

    echo "[$STEP/$TOTAL_STEPS] Building Flutter app..."
    cd "$PROJECT_ROOT/app"
    flutter pub get
    dart run build_runner build --delete-conflicting-outputs
    flutter build linux --release
    STEP=$((STEP + 1))
else
    echo "[$STEP/$TOTAL_STEPS] Skipping build (--skip-build)"
    STEP=$((STEP + 1))
fi

# Determine Flutter build output directory
if [ "$ARCH" = "arm64" ]; then
    FLUTTER_BUNDLE="$PROJECT_ROOT/app/build/linux/arm64/release/bundle"
else
    FLUTTER_BUNDLE="$PROJECT_ROOT/app/build/linux/x64/release/bundle"
fi

if [ ! -d "$FLUTTER_BUNDLE" ]; then
    echo "ERROR: Flutter build output not found at $FLUTTER_BUNDLE"
    echo "Build the app first or check architecture."
    exit 1
fi

# Create package structure
echo "[$STEP/$TOTAL_STEPS] Creating package structure..."
rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR"
mkdir -p "$DIST_DIR"

# Copy Flutter build output (executable, lib/, data/)
cp -r "$FLUTTER_BUNDLE/"* "$PACKAGE_DIR/"

STEP=$((STEP + 1))

# Copy Rust worker
echo "[$STEP/$TOTAL_STEPS] Copying worker and templates..."
WORKER_BIN="$PROJECT_ROOT/worker/target/release/vapourbox-worker"
if [ ! -f "$WORKER_BIN" ]; then
    echo "ERROR: Worker executable not found at $WORKER_BIN"
    exit 1
fi
cp "$WORKER_BIN" "$PACKAGE_DIR/"
chmod +x "$PACKAGE_DIR/vapourbox-worker"

# Copy VapourSynth templates
mkdir -p "$PACKAGE_DIR/templates"
cp "$PROJECT_ROOT/worker/templates/"*.vpy "$PACKAGE_DIR/templates/"
# Glob, not a list of names — see the note in package-macos.sh.
cp "$PROJECT_ROOT/worker/templates/"*.py "$PACKAGE_DIR/templates/"
cp "$PROJECT_ROOT/worker/templates/spotless.py" "$PACKAGE_DIR/templates/"

# Copy licenses
mkdir -p "$PACKAGE_DIR/licenses"
cp -r "$PROJECT_ROOT/licenses/"* "$PACKAGE_DIR/licenses/" 2>/dev/null || true
[ -f "$PROJECT_ROOT/LICENSE" ] && cp "$PROJECT_ROOT/LICENSE" "$PACKAGE_DIR/"

STEP=$((STEP + 1))

# Create tarball
echo "[$STEP/$TOTAL_STEPS] Creating tarball..."
cd "$DIST_DIR"
TAR_FILE="$PACKAGE_NAME.tar.gz"
tar -czf "$TAR_FILE" "$PACKAGE_NAME"

# Calculate size and hash
TAR_SIZE=$(stat -c%s "$TAR_FILE" 2>/dev/null || stat -f%z "$TAR_FILE" 2>/dev/null)
TAR_SIZE_MB=$(echo "scale=1; $TAR_SIZE / 1048576" | bc)
SHA256=$(sha256sum "$TAR_FILE" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$TAR_FILE" | cut -d' ' -f1)

# Cleanup unpacked directory
rm -rf "$PACKAGE_DIR"

echo ""
echo "=== Packaging Complete ==="
echo ""
echo "  Tarball: $DIST_DIR/$TAR_FILE"
echo "  Size:    ${TAR_SIZE_MB} MB"
echo "  SHA256:  $SHA256"
echo ""
echo "To install:"
echo "  tar -xzf $TAR_FILE"
echo "  cd $PACKAGE_NAME"
echo "  ./vapourbox"
echo ""
echo "Note: Dependencies will be downloaded on first launch."
