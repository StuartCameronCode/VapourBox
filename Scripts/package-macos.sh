#!/bin/bash
# Package iDeinterlace for macOS
# Creates a standalone .app bundle and optional .zip/.dmg
#
# Prerequisites:
# - Flutter SDK installed
# - Rust toolchain installed
# - Dependencies downloaded (run download-deps-macos.sh first)
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
APP_NAME="iDeinterlace"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DEPS_DIR="$PROJECT_ROOT/deps/macos-$ARCH"

echo "=== Packaging iDeinterlace for macOS ($ARCH) ==="
echo ""

# Check prerequisites
echo "[1/8] Checking prerequisites..."

if [ ! -d "$DEPS_DIR" ]; then
    echo "ERROR: Dependencies not found at $DEPS_DIR"
    echo "Run './Scripts/download-deps-macos.sh' first"
    exit 1
fi

if [ ! -f "$DEPS_DIR/vapoursynth/vspipe" ] && [ ! -f "$DEPS_DIR/bin/vspipe" ]; then
    echo "ERROR: VapourSynth (vspipe) not found in dependencies"
    exit 1
fi

if [ ! -f "$DEPS_DIR/ffmpeg/ffmpeg" ] && [ ! -f "$DEPS_DIR/bin/ffmpeg" ]; then
    echo "ERROR: FFmpeg not found in dependencies"
    exit 1
fi

echo "    Prerequisites OK"

# Build Rust worker
if [ "$SKIP_BUILD" = false ]; then
    echo "[2/8] Building Rust worker..."
    cd "$PROJECT_ROOT/worker"
    if [ "$ARCH" = "arm64" ]; then
        cargo build --release --target aarch64-apple-darwin
        WORKER_BIN="$PROJECT_ROOT/worker/target/aarch64-apple-darwin/release/ideinterlace-worker"
    else
        cargo build --release --target x86_64-apple-darwin
        WORKER_BIN="$PROJECT_ROOT/worker/target/x86_64-apple-darwin/release/ideinterlace-worker"
    fi
    # Fallback to default target if specific target not found
    if [ ! -f "$WORKER_BIN" ]; then
        cargo build --release
        WORKER_BIN="$PROJECT_ROOT/worker/target/release/ideinterlace-worker"
    fi
    echo "    Rust worker built"

    # Build Flutter app
    echo "[3/8] Building Flutter app..."
    cd "$PROJECT_ROOT/app"
    flutter pub get
    flutter build macos --release
    echo "    Flutter app built"
else
    echo "[2/8] Skipping Rust build (--skip-build)"
    echo "[3/8] Skipping Flutter build (--skip-build)"
    WORKER_BIN="$PROJECT_ROOT/worker/target/release/ideinterlace-worker"
fi

# Create app bundle structure
echo "[4/8] Creating app bundle structure..."
rm -rf "$APP_BUNDLE"
mkdir -p "$DIST_DIR"

# Copy Flutter app bundle as base
FLUTTER_APP="$PROJECT_ROOT/app/build/macos/Build/Products/Release/ideinterlace.app"
if [ ! -d "$FLUTTER_APP" ]; then
    echo "ERROR: Flutter app bundle not found at $FLUTTER_APP"
    exit 1
fi
cp -R "$FLUTTER_APP" "$APP_BUNDLE"

# Create additional directories
CONTENTS="$APP_BUNDLE/Contents"
mkdir -p "$CONTENTS/Helpers"
mkdir -p "$CONTENTS/Frameworks/VapourSynth"
mkdir -p "$CONTENTS/Resources/PythonPackages"
mkdir -p "$CONTENTS/Resources/Templates"
mkdir -p "$CONTENTS/Resources/NNEDI3"

# Copy Rust worker
echo "[5/8] Copying Rust worker..."
if [ ! -f "$WORKER_BIN" ]; then
    echo "ERROR: Worker executable not found at $WORKER_BIN"
    exit 1
fi
cp "$WORKER_BIN" "$CONTENTS/Helpers/ideinterlace-worker"
chmod +x "$CONTENTS/Helpers/ideinterlace-worker"

# Copy VapourSynth script templates
cp "$PROJECT_ROOT/worker/templates/qtgmc_template.vpy" "$CONTENTS/Resources/Templates/"
cp "$PROJECT_ROOT/worker/templates/pipeline_template.vpy" "$CONTENTS/Resources/Templates/"

# Copy dependencies
echo "[6/8] Copying dependencies..."

# Determine dependency layout (varies by how deps were downloaded)
if [ -d "$DEPS_DIR/vapoursynth" ]; then
    VS_DIR="$DEPS_DIR/vapoursynth"
    FFMPEG_DIR="$DEPS_DIR/ffmpeg"
    PYTHON_DIR="$DEPS_DIR/python"
    PYTHON_PACKAGES="$DEPS_DIR/python-packages"
elif [ -d "$DEPS_DIR/lib/vapoursynth" ]; then
    VS_DIR="$DEPS_DIR"
    FFMPEG_DIR="$DEPS_DIR"
    PYTHON_DIR="$DEPS_DIR"
    PYTHON_PACKAGES="$DEPS_DIR/lib/python3.11/site-packages"
else
    echo "ERROR: Could not determine dependency layout in $DEPS_DIR"
    exit 1
fi

# Copy vspipe
echo "    Copying vspipe..."
if [ -f "$VS_DIR/vspipe" ]; then
    cp "$VS_DIR/vspipe" "$CONTENTS/Helpers/"
elif [ -f "$VS_DIR/bin/vspipe" ]; then
    cp "$VS_DIR/bin/vspipe" "$CONTENTS/Helpers/"
fi
chmod +x "$CONTENTS/Helpers/vspipe"

# Copy ffmpeg
echo "    Copying ffmpeg..."
if [ -f "$FFMPEG_DIR/ffmpeg" ]; then
    cp "$FFMPEG_DIR/ffmpeg" "$CONTENTS/Helpers/"
elif [ -f "$FFMPEG_DIR/bin/ffmpeg" ]; then
    cp "$FFMPEG_DIR/bin/ffmpeg" "$CONTENTS/Helpers/"
fi
chmod +x "$CONTENTS/Helpers/ffmpeg"

# Copy ffprobe if available
if [ -f "$FFMPEG_DIR/ffprobe" ]; then
    cp "$FFMPEG_DIR/ffprobe" "$CONTENTS/Helpers/"
    chmod +x "$CONTENTS/Helpers/ffprobe"
elif [ -f "$FFMPEG_DIR/bin/ffprobe" ]; then
    cp "$FFMPEG_DIR/bin/ffprobe" "$CONTENTS/Helpers/"
    chmod +x "$CONTENTS/Helpers/ffprobe"
fi

# Copy VapourSynth libraries
echo "    Copying VapourSynth libraries..."
if [ -d "$VS_DIR/lib" ]; then
    cp -R "$VS_DIR/lib/"*.dylib "$CONTENTS/Frameworks/" 2>/dev/null || true
fi
if [ -f "$VS_DIR/libvapoursynth.dylib" ]; then
    cp "$VS_DIR/libvapoursynth.dylib" "$CONTENTS/Frameworks/"
fi
if [ -f "$VS_DIR/libvapoursynth-script.dylib" ]; then
    cp "$VS_DIR/libvapoursynth-script.dylib" "$CONTENTS/Frameworks/"
fi

# Copy VapourSynth plugins
echo "    Copying VapourSynth plugins..."
if [ -d "$VS_DIR/plugins" ]; then
    cp -R "$VS_DIR/plugins/"* "$CONTENTS/Frameworks/VapourSynth/" 2>/dev/null || true
elif [ -d "$VS_DIR/lib/vapoursynth" ]; then
    cp -R "$VS_DIR/lib/vapoursynth/"* "$CONTENTS/Frameworks/VapourSynth/" 2>/dev/null || true
fi

# Copy NNEDI3 weights
if [ -f "$VS_DIR/nnedi3_weights.bin" ]; then
    cp "$VS_DIR/nnedi3_weights.bin" "$CONTENTS/Resources/NNEDI3/"
elif [ -f "$DEPS_DIR/share/nnedi3/nnedi3_weights.bin" ]; then
    cp "$DEPS_DIR/share/nnedi3/nnedi3_weights.bin" "$CONTENTS/Resources/NNEDI3/"
fi

# Copy Python packages
echo "    Copying Python packages..."
if [ -d "$PYTHON_PACKAGES" ]; then
    # Copy essential packages
    for pkg in havsfunc.py mvsfunc mvsfunc.py adjust vsutil functool; do
        if [ -e "$PYTHON_PACKAGES/$pkg" ]; then
            cp -R "$PYTHON_PACKAGES/$pkg" "$CONTENTS/Resources/PythonPackages/" 2>/dev/null || true
        fi
    done
fi

# Copy Python framework if available
echo "    Copying Python framework..."
if [ -d "$PYTHON_DIR/Python.framework" ]; then
    cp -R "$PYTHON_DIR/Python.framework" "$CONTENTS/Frameworks/"
    # Clean up Python framework
    find "$CONTENTS/Frameworks/Python.framework" -name "*.pyc" -delete 2>/dev/null || true
    find "$CONTENTS/Frameworks/Python.framework" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
elif [ -d "$DEPS_DIR/Frameworks/Python.framework" ]; then
    cp -R "$DEPS_DIR/Frameworks/Python.framework" "$CONTENTS/Frameworks/"
fi

# Create vspipe wrapper script
echo "[7/8] Creating wrapper scripts..."
if [ -f "$CONTENTS/Helpers/vspipe" ]; then
    mv "$CONTENTS/Helpers/vspipe" "$CONTENTS/Helpers/vspipe-bin"
    cat > "$CONTENTS/Helpers/vspipe" << 'WRAPPER'
#!/bin/bash
BUNDLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Set up Python environment
if [ -d "$BUNDLE_DIR/Frameworks/Python.framework" ]; then
    PYTHON_VERSION=$(ls "$BUNDLE_DIR/Frameworks/Python.framework/Versions" | grep -E '^3\.' | head -1)
    export PYTHONHOME="$BUNDLE_DIR/Frameworks/Python.framework/Versions/$PYTHON_VERSION"
    export PYTHONPATH="$BUNDLE_DIR/Resources/PythonPackages:$PYTHONHOME/lib/python$PYTHON_VERSION/site-packages"
else
    export PYTHONPATH="$BUNDLE_DIR/Resources/PythonPackages"
fi

# Set up VapourSynth environment
export VAPOURSYNTH_PLUGIN_PATH="$BUNDLE_DIR/Frameworks/VapourSynth"
export DYLD_LIBRARY_PATH="$BUNDLE_DIR/Frameworks:$DYLD_LIBRARY_PATH"

# NNEDI3 weights
if [ -f "$BUNDLE_DIR/Resources/NNEDI3/nnedi3_weights.bin" ]; then
    export NNEDI3_WEIGHTS_PATH="$BUNDLE_DIR/Resources/NNEDI3/nnedi3_weights.bin"
fi

# Clear conda/virtualenv that might interfere
unset CONDA_PREFIX CONDA_DEFAULT_ENV VIRTUAL_ENV

exec "$BUNDLE_DIR/Helpers/vspipe-bin" "$@"
WRAPPER
    chmod +x "$CONTENTS/Helpers/vspipe"
fi

# Update Info.plist with version
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$CONTENTS/Info.plist" 2>/dev/null || true

# Sign all binaries
echo "[8/8] Signing binaries..."
find "$CONTENTS" -type f \( -name "*.dylib" -o -name "*.so" -o -perm +111 \) -exec codesign --force --sign - {} \; 2>/dev/null || true
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true

# Calculate size
APP_SIZE=$(du -sh "$APP_BUNDLE" | cut -f1)

echo ""
echo "=== Packaging Complete ==="
echo ""
echo "App bundle created: $APP_BUNDLE"
echo "Bundle size: $APP_SIZE"
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
