#!/bin/bash
# Build a fully standalone distributable VapourBox.app
# This bundles Python, VapourSynth, ffmpeg, and all required plugins
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_ROOT/.build/release"
APP_NAME="VapourBox"
APP_BUNDLE="$PROJECT_ROOT/dist/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"

# Source paths (from Homebrew)
HOMEBREW_PREFIX="/opt/homebrew"
PYTHON_VERSION="3.14"
PYTHON_FRAMEWORK="$HOMEBREW_PREFIX/opt/python@$PYTHON_VERSION/Frameworks/Python.framework"

echo "=== Building Standalone VapourBox.app ==="
echo ""

# Step 1: Build Swift executables
echo "[1/8] Building Swift executables..."
cd "$PROJECT_ROOT"
swift build -c release 2>&1 | grep -E "(Build|error:|warning:.*error)" || true
echo "    Build complete"

# Step 2: Create app bundle structure
echo "[2/8] Creating app bundle structure..."
rm -rf "$APP_BUNDLE"
mkdir -p "$CONTENTS/MacOS"
mkdir -p "$CONTENTS/Helpers"
mkdir -p "$CONTENTS/Frameworks"
mkdir -p "$CONTENTS/PlugIns/VapourSynth"
mkdir -p "$CONTENTS/Resources/PythonPackages"
mkdir -p "$CONTENTS/Resources/NNEDI3CL"
mkdir -p "$CONTENTS/lib"

# Step 3: Copy executables
echo "[3/8] Copying executables..."
cp "$BUILD_DIR/VapourBox" "$CONTENTS/MacOS/"
cp "$BUILD_DIR/VapourBoxWorker" "$CONTENTS/Helpers/"

# Step 4: Copy Python framework
echo "[4/8] Copying Python framework..."
if [ -d "$PYTHON_FRAMEWORK" ]; then
    cp -R "$PYTHON_FRAMEWORK" "$CONTENTS/Frameworks/"
    # Remove unnecessary files to reduce size
    find "$CONTENTS/Frameworks/Python.framework" -name "*.pyc" -delete 2>/dev/null || true
    find "$CONTENTS/Frameworks/Python.framework" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
    rm -rf "$CONTENTS/Frameworks/Python.framework/Versions/$PYTHON_VERSION/share" 2>/dev/null || true
    rm -rf "$CONTENTS/Frameworks/Python.framework/Versions/$PYTHON_VERSION/lib/python$PYTHON_VERSION/test" 2>/dev/null || true
    echo "    Python framework copied"
else
    echo "    ERROR: Python framework not found at $PYTHON_FRAMEWORK"
    exit 1
fi

# Step 5: Copy vspipe and ffmpeg
echo "[5/8] Copying vspipe and ffmpeg..."
cp "$HOMEBREW_PREFIX/bin/vspipe" "$CONTENTS/Helpers/"
cp "$HOMEBREW_PREFIX/bin/ffmpeg" "$CONTENTS/Helpers/"

# Copy libvapoursynth
cp "$HOMEBREW_PREFIX/lib/libvapoursynth.dylib" "$CONTENTS/lib/"
cp "$HOMEBREW_PREFIX/lib/libvapoursynth-script.dylib" "$CONTENTS/lib/"

# Step 6: Copy VapourSynth plugins
echo "[6/8] Copying VapourSynth plugins..."
VS_PLUGINS="$HOMEBREW_PREFIX/lib/vapoursynth"
for plugin in libffms2.dylib libmvtools.dylib libnnedi3.dylib libfmtconv.dylib \
              libmiscfilters.dylib libresize2.dylib libnnedi3cl.dylib; do
    if [ -f "$VS_PLUGINS/$plugin" ]; then
        cp "$VS_PLUGINS/$plugin" "$CONTENTS/PlugIns/VapourSynth/"
        echo "    Copied $plugin"
    else
        echo "    Warning: $plugin not found"
    fi
done

# Copy NNEDI3 weights
if [ -f "$HOMEBREW_PREFIX/share/NNEDI3CL/nnedi3_weights.bin" ]; then
    cp "$HOMEBREW_PREFIX/share/NNEDI3CL/nnedi3_weights.bin" "$CONTENTS/Resources/NNEDI3CL/"
elif [ -f "/opt/homebrew/share/nnedi3/nnedi3_weights.bin" ]; then
    cp "/opt/homebrew/share/nnedi3/nnedi3_weights.bin" "$CONTENTS/Resources/NNEDI3CL/"
fi

# Step 7: Copy Python packages
echo "[7/8] Copying Python packages..."
# Try multiple locations for site-packages
SITE_PACKAGES=""
for sp in "$HOMEBREW_PREFIX/lib/python$PYTHON_VERSION/site-packages" \
          "$PYTHON_FRAMEWORK/Versions/$PYTHON_VERSION/lib/python$PYTHON_VERSION/site-packages"; do
    if [ -d "$sp" ]; then
        SITE_PACKAGES="$sp"
        break
    fi
done
DEST_PACKAGES="$CONTENTS/Resources/PythonPackages"

if [ -z "$SITE_PACKAGES" ]; then
    echo "    Warning: Could not find site-packages directory"
else
    echo "    Using site-packages: $SITE_PACKAGES"

    # Copy havsfunc
    if [ -f "$SITE_PACKAGES/havsfunc.py" ]; then
        cp "$SITE_PACKAGES/havsfunc.py" "$DEST_PACKAGES/"
        echo "    Copied havsfunc.py"
    else
        echo "    Warning: havsfunc.py not found"
    fi

    # Copy mvsfunc (as package directory)
    if [ -d "$SITE_PACKAGES/mvsfunc" ]; then
        cp -R "$SITE_PACKAGES/mvsfunc" "$DEST_PACKAGES/"
        echo "    Copied mvsfunc/"
    elif [ -f "$SITE_PACKAGES/mvsfunc.py" ]; then
        cp "$SITE_PACKAGES/mvsfunc.py" "$DEST_PACKAGES/"
        echo "    Copied mvsfunc.py"
    else
        echo "    Warning: mvsfunc not found"
    fi

    # Copy adjust
    if [ -d "$SITE_PACKAGES/adjust" ]; then
        cp -R "$SITE_PACKAGES/adjust" "$DEST_PACKAGES/"
        echo "    Copied adjust/"
    fi

    # Copy vsutil if present
    if [ -d "$SITE_PACKAGES/vsutil" ]; then
        cp -R "$SITE_PACKAGES/vsutil" "$DEST_PACKAGES/"
        echo "    Copied vsutil/"
    fi

    # Copy functool if present (dependency)
    if [ -d "$SITE_PACKAGES/functool" ]; then
        cp -R "$SITE_PACKAGES/functool" "$DEST_PACKAGES/"
        echo "    Copied functool/"
    fi
fi

# Step 8: Fix library paths
echo "[8/8] Fixing library paths and signing..."

# Fix vspipe to use bundled Python
install_name_tool -change \
    "$HOMEBREW_PREFIX/opt/python@$PYTHON_VERSION/Frameworks/Python.framework/Versions/$PYTHON_VERSION/Python" \
    "@executable_path/../Frameworks/Python.framework/Versions/$PYTHON_VERSION/Python" \
    "$CONTENTS/Helpers/vspipe" 2>/dev/null || true

# Fix vspipe libvapoursynth references
install_name_tool -change \
    "$HOMEBREW_PREFIX/lib/libvapoursynth-script.0.dylib" \
    "@executable_path/../lib/libvapoursynth-script.dylib" \
    "$CONTENTS/Helpers/vspipe" 2>/dev/null || true

# Fix libvapoursynth-script
install_name_tool -change \
    "$HOMEBREW_PREFIX/opt/python@$PYTHON_VERSION/Frameworks/Python.framework/Versions/$PYTHON_VERSION/Python" \
    "@loader_path/../Frameworks/Python.framework/Versions/$PYTHON_VERSION/Python" \
    "$CONTENTS/lib/libvapoursynth-script.dylib" 2>/dev/null || true

install_name_tool -change \
    "$HOMEBREW_PREFIX/lib/libvapoursynth.0.dylib" \
    "@loader_path/libvapoursynth.dylib" \
    "$CONTENTS/lib/libvapoursynth-script.dylib" 2>/dev/null || true

install_name_tool -id "@loader_path/libvapoursynth-script.dylib" \
    "$CONTENTS/lib/libvapoursynth-script.dylib" 2>/dev/null || true

# Fix libvapoursynth
install_name_tool -id "@loader_path/libvapoursynth.dylib" \
    "$CONTENTS/lib/libvapoursynth.dylib" 2>/dev/null || true

# Create vspipe wrapper script that sets up environment
mv "$CONTENTS/Helpers/vspipe" "$CONTENTS/Helpers/vspipe-bin"
cat > "$CONTENTS/Helpers/vspipe" << 'WRAPPER'
#!/bin/bash
BUNDLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PYTHONHOME="$BUNDLE_DIR/Frameworks/Python.framework/Versions/3.14"
export PYTHONPATH="$BUNDLE_DIR/Resources/PythonPackages:$PYTHONHOME/lib/python3.14/site-packages"
export VAPOURSYNTH_PLUGIN_PATH="$BUNDLE_DIR/PlugIns/VapourSynth"
export NNEDI3CL_WEIGHTS_PATH="$BUNDLE_DIR/Resources/NNEDI3CL/nnedi3_weights.bin"
export DYLD_LIBRARY_PATH="$BUNDLE_DIR/lib:$DYLD_LIBRARY_PATH"
# Clear conda/virtualenv that might interfere
unset CONDA_PREFIX CONDA_DEFAULT_ENV VIRTUAL_ENV
exec "$BUNDLE_DIR/Helpers/vspipe-bin" "$@"
WRAPPER
chmod +x "$CONTENTS/Helpers/vspipe"

# Create Info.plist
cat > "$CONTENTS/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>VapourBox</string>
    <key>CFBundleIdentifier</key>
    <string>com.stuartcameron.VapourBox</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>VapourBox</string>
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

echo -n "APPL????" > "$CONTENTS/PkgInfo"

# Sign all binaries
echo "    Signing binaries..."
find "$CONTENTS" -type f \( -name "*.dylib" -o -name "*.so" -o -perm +111 \) -exec codesign --force --sign - {} \; 2>/dev/null || true
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true

echo ""
echo "=== Build Complete ==="
echo ""
echo "Standalone app bundle created at:"
echo "  $APP_BUNDLE"
echo ""
echo "Bundle size:"
du -sh "$APP_BUNDLE"
echo ""
echo "To install:"
echo "  cp -R '$APP_BUNDLE' /Applications/"
echo ""
echo "To test:"
echo "  open '$APP_BUNDLE'"
