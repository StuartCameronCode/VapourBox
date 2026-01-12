#!/bin/bash
# Setup TestBundle with dependencies for running integration tests
# This creates a self-contained bundle that doesn't require host machine setup

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TEST_BUNDLE="$PROJECT_ROOT/Tests/TestBundle"

echo "Setting up TestBundle at: $TEST_BUNDLE"

# Check for Homebrew
if ! command -v brew &> /dev/null; then
    echo "Error: Homebrew is required to build the test bundle"
    exit 1
fi

# Create directory structure
mkdir -p "$TEST_BUNDLE/Helpers"
mkdir -p "$TEST_BUNDLE/Frameworks"
mkdir -p "$TEST_BUNDLE/PlugIns/VapourSynth"
mkdir -p "$TEST_BUNDLE/Resources"
mkdir -p "$TEST_BUNDLE/PythonPackages"

# Find Python version
PYTHON_VERSION=$(python3.14 --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "3.14")
PYTHON_CELLAR=$(brew --prefix python@3.14)/Frameworks/Python.framework

echo "Using Python $PYTHON_VERSION from: $PYTHON_CELLAR"

# Copy Python framework (minimal - just what VapourSynth needs)
if [ -d "$PYTHON_CELLAR" ]; then
    echo "Copying Python framework..."
    cp -R "$PYTHON_CELLAR" "$TEST_BUNDLE/Frameworks/"
else
    echo "Error: Python framework not found at $PYTHON_CELLAR"
    exit 1
fi

# Copy vspipe
VSPIPE_PATH=$(which vspipe)
if [ -n "$VSPIPE_PATH" ]; then
    echo "Copying vspipe from: $VSPIPE_PATH"
    cp "$VSPIPE_PATH" "$TEST_BUNDLE/Helpers/"
else
    echo "Error: vspipe not found"
    exit 1
fi

# Copy ffmpeg
FFMPEG_PATH=$(which ffmpeg)
if [ -n "$FFMPEG_PATH" ]; then
    echo "Copying ffmpeg from: $FFMPEG_PATH"
    cp "$FFMPEG_PATH" "$TEST_BUNDLE/Helpers/"
else
    echo "Error: ffmpeg not found"
    exit 1
fi

# Copy VapourSynth plugins
VS_PLUGINS="/opt/homebrew/lib/vapoursynth"
if [ -d "$VS_PLUGINS" ]; then
    echo "Copying VapourSynth plugins..."
    cp "$VS_PLUGINS"/*.dylib "$TEST_BUNDLE/PlugIns/VapourSynth/" 2>/dev/null || true
else
    echo "Warning: VapourSynth plugins directory not found"
fi

# Copy Python packages needed for QTGMC
SITE_PACKAGES="/opt/homebrew/lib/python${PYTHON_VERSION}/site-packages"
if [ -d "$SITE_PACKAGES" ]; then
    echo "Copying Python packages..."
    # Copy havsfunc (QTGMC)
    [ -f "$SITE_PACKAGES/havsfunc.py" ] && cp "$SITE_PACKAGES/havsfunc.py" "$TEST_BUNDLE/PythonPackages/"
    # Copy mvsfunc (as package directory if available, otherwise the file)
    if [ -d "$SITE_PACKAGES/mvsfunc" ]; then
        cp -R "$SITE_PACKAGES/mvsfunc" "$TEST_BUNDLE/PythonPackages/"
    elif [ -f "$SITE_PACKAGES/mvsfunc.py" ]; then
        cp "$SITE_PACKAGES/mvsfunc.py" "$TEST_BUNDLE/PythonPackages/"
    fi
    # Copy adjust
    [ -d "$SITE_PACKAGES/adjust" ] && cp -R "$SITE_PACKAGES/adjust" "$TEST_BUNDLE/PythonPackages/"
    # Copy functools for adjust dependency
    [ -f "$SITE_PACKAGES/functools.py" ] && cp "$SITE_PACKAGES/functools.py" "$TEST_BUNDLE/PythonPackages/"
else
    echo "Warning: Python site-packages not found at $SITE_PACKAGES"
fi

# Copy NNEDI3CL weights
NNEDI3_WEIGHTS="/opt/homebrew/share/NNEDI3CL/nnedi3_weights.bin"
if [ -f "$NNEDI3_WEIGHTS" ]; then
    echo "Copying NNEDI3CL weights..."
    mkdir -p "$TEST_BUNDLE/Resources/NNEDI3CL"
    cp "$NNEDI3_WEIGHTS" "$TEST_BUNDLE/Resources/NNEDI3CL/"
fi

# Copy required dylibs that vspipe/plugins depend on
echo "Copying library dependencies..."
DYLIB_DIR="$TEST_BUNDLE/lib"
mkdir -p "$DYLIB_DIR"

# Copy VapourSynth core library
VS_LIB=$(brew --prefix vapoursynth)/lib/libvapoursynth.dylib
if [ -f "$VS_LIB" ]; then
    cp "$VS_LIB" "$DYLIB_DIR/"
fi

VS_SCRIPT_LIB=$(brew --prefix vapoursynth)/lib/libvapoursynth-script.dylib
if [ -f "$VS_SCRIPT_LIB" ]; then
    cp "$VS_SCRIPT_LIB" "$DYLIB_DIR/"
fi

# Fix library paths in vspipe and libraries using install_name_tool
echo "Fixing library paths..."

PYTHON_FRAMEWORK="$TEST_BUNDLE/Frameworks/Python.framework"
PYTHON_LIB="$PYTHON_FRAMEWORK/Versions/3.14/Python"
VS_LIB_DIR="$TEST_BUNDLE/lib"

# Fix vspipe to use bundled Python and VapourSynth
if [ -f "$TEST_BUNDLE/Helpers/vspipe" ]; then
    # Change Python framework reference
    install_name_tool -change \
        "/opt/homebrew/opt/python@3.14/Frameworks/Python.framework/Versions/3.14/Python" \
        "@executable_path/../Frameworks/Python.framework/Versions/3.14/Python" \
        "$TEST_BUNDLE/Helpers/vspipe" 2>/dev/null || true

    # Change VapourSynth script library reference
    install_name_tool -change \
        "/opt/homebrew/Cellar/vapoursynth/73/lib/libvapoursynth-script.0.dylib" \
        "@executable_path/../lib/libvapoursynth-script.dylib" \
        "$TEST_BUNDLE/Helpers/vspipe" 2>/dev/null || true
fi

# Fix libvapoursynth-script.dylib
if [ -f "$VS_LIB_DIR/libvapoursynth-script.dylib" ]; then
    install_name_tool -id "@rpath/libvapoursynth-script.dylib" \
        "$VS_LIB_DIR/libvapoursynth-script.dylib" 2>/dev/null || true

    install_name_tool -change \
        "/opt/homebrew/opt/python@3.14/Frameworks/Python.framework/Versions/3.14/Python" \
        "@loader_path/../Frameworks/Python.framework/Versions/3.14/Python" \
        "$VS_LIB_DIR/libvapoursynth-script.dylib" 2>/dev/null || true

    install_name_tool -change \
        "/opt/homebrew/Cellar/vapoursynth/73/lib/libvapoursynth.0.dylib" \
        "@loader_path/libvapoursynth.dylib" \
        "$VS_LIB_DIR/libvapoursynth-script.dylib" 2>/dev/null || true
fi

# Fix libvapoursynth.dylib
if [ -f "$VS_LIB_DIR/libvapoursynth.dylib" ]; then
    install_name_tool -id "@rpath/libvapoursynth.dylib" \
        "$VS_LIB_DIR/libvapoursynth.dylib" 2>/dev/null || true
fi

# Fix Python framework library
if [ -f "$PYTHON_LIB" ]; then
    install_name_tool -id "@rpath/Python" "$PYTHON_LIB" 2>/dev/null || true
fi

# Fix VapourSynth plugins
for plugin in "$TEST_BUNDLE/PlugIns/VapourSynth"/*.dylib; do
    if [ -f "$plugin" ]; then
        install_name_tool -change \
            "/opt/homebrew/Cellar/vapoursynth/73/lib/libvapoursynth.0.dylib" \
            "@loader_path/../../lib/libvapoursynth.dylib" \
            "$plugin" 2>/dev/null || true
    fi
done

# Re-sign binaries after modifying paths (required by macOS)
echo "Re-signing binaries..."
codesign --force --sign - "$TEST_BUNDLE/Helpers/vspipe" 2>/dev/null || true
codesign --force --sign - "$TEST_BUNDLE/Helpers/ffmpeg" 2>/dev/null || true
codesign --force --sign - "$VS_LIB_DIR/libvapoursynth-script.dylib" 2>/dev/null || true
codesign --force --sign - "$VS_LIB_DIR/libvapoursynth.dylib" 2>/dev/null || true
codesign --force --sign - "$PYTHON_LIB" 2>/dev/null || true
for plugin in "$TEST_BUNDLE/PlugIns/VapourSynth"/*.dylib; do
    codesign --force --sign - "$plugin" 2>/dev/null || true
done

# Create wrapper script for vspipe that sets up the environment
# Rename binary to vspipe-bin and create wrapper as vspipe
mv "$TEST_BUNDLE/Helpers/vspipe" "$TEST_BUNDLE/Helpers/vspipe-bin"
cat > "$TEST_BUNDLE/Helpers/vspipe" << 'WRAPPER'
#!/bin/bash
BUNDLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PYTHONHOME="$BUNDLE_DIR/Frameworks/Python.framework/Versions/3.14"
export PYTHONPATH="$BUNDLE_DIR/PythonPackages:$PYTHONHOME/lib/python3.14/site-packages"
export VAPOURSYNTH_PLUGIN_PATH="$BUNDLE_DIR/PlugIns/VapourSynth"
export NNEDI3CL_WEIGHTS_PATH="$BUNDLE_DIR/Resources/NNEDI3CL/nnedi3_weights.bin"
exec "$BUNDLE_DIR/Helpers/vspipe-bin" "$@"
WRAPPER
chmod +x "$TEST_BUNDLE/Helpers/vspipe"

# Create a marker file to indicate bundle is set up
echo "$(date)" > "$TEST_BUNDLE/.setup-complete"

echo ""
echo "TestBundle setup complete!"
echo "Contents:"
find "$TEST_BUNDLE" -type f | head -30
echo ""
echo "To run tests: swift test --filter testDeinterlaceAVI"
