#!/bin/bash
# Download and build dependencies for VapourBox on macOS (native arm64/x64)
# Builds VapourSynth plugins from source for native architecture support
# Creates a fully self-contained app with no Homebrew runtime dependencies
#
# Prerequisites:
# - Homebrew (for build tools only, not runtime)
# - Xcode Command Line Tools
#
# Usage: ./scripts/download-deps-macos.sh [--force]

set -e

FORCE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            FORCE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--force]"
            exit 1
            ;;
    esac
done

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    PLATFORM_DIR="macos-arm64"
elif [ "$ARCH" = "x86_64" ]; then
    PLATFORM_DIR="macos-x64"
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DEPS_DIR="$PROJECT_ROOT/deps/$PLATFORM_DIR"
PLUGINS_DIR="$DEPS_DIR/vapoursynth/plugins"
PYTHON_DIR="$DEPS_DIR/python"
PYTHON_PACKAGES_DIR="$DEPS_DIR/python-packages"
BUILD_DIR="/tmp/vapourbox-build-$$"

# Python version to embed
PYTHON_VERSION="3.12.8"
PYTHON_MAJOR_MINOR="3.12"

echo "=== VapourBox macOS Dependencies Builder ==="
echo "Architecture: $ARCH"
echo "Platform: $PLATFORM_DIR"
echo "Deps directory: $DEPS_DIR"
echo "Build directory: $BUILD_DIR"
echo "Force rebuild: $FORCE"
echo ""

# Create directories
mkdir -p "$DEPS_DIR"/{vapoursynth,ffmpeg,python,python-packages,resources/NNEDI3CL}
mkdir -p "$PLUGINS_DIR"
mkdir -p "$BUILD_DIR"

# Get Homebrew prefix (for build tools only)
BREW_PREFIX=$(brew --prefix)

# ============================================================================
# Install Homebrew build dependencies (used only at build time, not runtime)
# ============================================================================
echo "=== Installing Homebrew build dependencies ==="

BREW_DEPS=(
    # Build tools
    cmake meson ninja nasm autoconf automake libtool pkg-config cython
    # Libraries needed to build (will be copied, not linked at runtime from homebrew)
    fftw zimg
    # FFmpeg (will be copied)
    ffmpeg ffms2
)

for dep in "${BREW_DEPS[@]}"; do
    if ! brew list "$dep" &>/dev/null; then
        echo "Installing $dep..."
        brew install "$dep"
    else
        echo "  $dep already installed"
    fi
done

# ============================================================================
# Download and embed Python framework
# ============================================================================
echo ""
echo "=== Downloading embedded Python $PYTHON_VERSION ==="

PYTHON_FRAMEWORK_DIR="$PYTHON_DIR/Python.framework"

if [ "$FORCE" = true ] || [ ! -d "$PYTHON_FRAMEWORK_DIR" ]; then
    # Download python.org universal installer and extract the framework
    # Using python-build-standalone for a relocatable Python
    PYTHON_STANDALONE_URL="https://github.com/indygreg/python-build-standalone/releases/download/20241206/cpython-${PYTHON_VERSION}+20241206-aarch64-apple-darwin-install_only_stripped.tar.gz"
    if [ "$ARCH" = "x86_64" ]; then
        PYTHON_STANDALONE_URL="https://github.com/indygreg/python-build-standalone/releases/download/20241206/cpython-${PYTHON_VERSION}+20241206-x86_64-apple-darwin-install_only_stripped.tar.gz"
    fi

    echo "  Downloading python-build-standalone..."
    curl -L -o "$BUILD_DIR/python-standalone.tar.gz" "$PYTHON_STANDALONE_URL"

    echo "  Extracting Python..."
    rm -rf "$PYTHON_DIR"/*
    mkdir -p "$PYTHON_DIR"
    tar -xzf "$BUILD_DIR/python-standalone.tar.gz" -C "$PYTHON_DIR" --strip-components=1

    # Create symlinks for compatibility
    PYTHON_BIN="$PYTHON_DIR/bin/python${PYTHON_MAJOR_MINOR}"

    echo "  Python installed to: $PYTHON_DIR"
    "$PYTHON_BIN" --version
else
    echo "  Python already installed, skipping"
fi

# Set Python paths for building
PYTHON_BIN="$PYTHON_DIR/bin/python${PYTHON_MAJOR_MINOR}"
PYTHON_LIB="$PYTHON_DIR/lib/libpython${PYTHON_MAJOR_MINOR}.dylib"
PYTHON_INCLUDE="$PYTHON_DIR/include/python${PYTHON_MAJOR_MINOR}"

# ============================================================================
# Build VapourSynth from source with embedded Python
# ============================================================================
echo ""
echo "=== Building VapourSynth from source ==="

VS_BUILD_DIR="$BUILD_DIR/vapoursynth"
VS_INSTALL_DIR="$BUILD_DIR/vapoursynth-install"

if [ "$FORCE" = true ] || [ ! -f "$DEPS_DIR/vapoursynth/libvapoursynth.dylib" ]; then
    echo "  Cloning VapourSynth R73..."
    rm -rf "$VS_BUILD_DIR"
    git clone --depth 1 --branch R73 https://github.com/vapoursynth/vapoursynth.git "$VS_BUILD_DIR" 2>/dev/null || \
    git clone --depth 1 https://github.com/vapoursynth/vapoursynth.git "$VS_BUILD_DIR"

    cd "$VS_BUILD_DIR"

    # Install Cython in our embedded Python for building
    echo "  Installing Cython in embedded Python..."
    "$PYTHON_BIN" -m pip install --quiet cython

    # Create pkg-config file for our embedded Python
    mkdir -p "$BUILD_DIR/pkgconfig"
    cat > "$BUILD_DIR/pkgconfig/python3.pc" << EOF
prefix=$PYTHON_DIR
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: Python
Description: Embedded Python
Version: $PYTHON_VERSION
Libs: -L\${libdir} -lpython${PYTHON_MAJOR_MINOR}
Cflags: -I\${includedir}/python${PYTHON_MAJOR_MINOR}
EOF
    cat > "$BUILD_DIR/pkgconfig/python-${PYTHON_MAJOR_MINOR}.pc" << EOF
prefix=$PYTHON_DIR
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: Python
Description: Embedded Python
Version: $PYTHON_VERSION
Libs: -L\${libdir} -lpython${PYTHON_MAJOR_MINOR}
Cflags: -I\${includedir}/python${PYTHON_MAJOR_MINOR}
EOF
    cp "$BUILD_DIR/pkgconfig/python-${PYTHON_MAJOR_MINOR}.pc" "$BUILD_DIR/pkgconfig/python3-embed.pc"

    echo "  Configuring VapourSynth..."
    # Configure with no system plugin path and using our embedded Python
    PATH="$PYTHON_DIR/bin:$BREW_PREFIX/opt/cython/bin:$PATH" \
    PKG_CONFIG_PATH="$BUILD_DIR/pkgconfig:$BREW_PREFIX/lib/pkgconfig" \
    meson setup build \
        --prefix="$VS_INSTALL_DIR" \
        --buildtype=release \
        -Dlibdir=lib \
        -Dplugindir="" \
        -Dpython3_bin="$PYTHON_BIN"

    echo "  Building VapourSynth..."
    PATH="$PYTHON_DIR/bin:$PATH" ninja -C build
    PATH="$PYTHON_DIR/bin:$PATH" ninja -C build install

    echo "  Copying VapourSynth files..."
    # Copy vspipe
    cp "$VS_INSTALL_DIR/bin/vspipe" "$DEPS_DIR/vapoursynth/vspipe-bin"
    chmod +x "$DEPS_DIR/vapoursynth/vspipe-bin"

    # Copy libraries with both names for compatibility
    cp "$VS_INSTALL_DIR/lib/libvapoursynth.4.dylib" "$DEPS_DIR/vapoursynth/libvapoursynth.dylib"
    cp "$VS_INSTALL_DIR/lib/libvapoursynth.4.dylib" "$DEPS_DIR/vapoursynth/libvapoursynth.4.dylib"
    cp "$VS_INSTALL_DIR/lib/libvapoursynth-script.4.dylib" "$DEPS_DIR/vapoursynth/libvapoursynth-script.dylib"
    cp "$VS_INSTALL_DIR/lib/libvapoursynth-script.4.dylib" "$DEPS_DIR/vapoursynth/libvapoursynth-script.4.dylib"

    # Copy zimg from Homebrew (will fix paths to be relative)
    cp "$BREW_PREFIX/lib/libzimg.2.dylib" "$DEPS_DIR/vapoursynth/libzimg.dylib"

    # Copy Python module
    find "$VS_BUILD_DIR/build" -name "vapoursynth*.so" -exec cp {} "$PYTHON_PACKAGES_DIR/" \;

    # Fix Python module library paths (critical for self-contained operation)
    cd "$PYTHON_PACKAGES_DIR"
    for so_file in vapoursynth.cpython-*.so; do
        if [ -f "$so_file" ]; then
            # Fix libvapoursynth reference to use loader_path
            install_name_tool -change "@rpath/libvapoursynth.4.dylib" \
                "@loader_path/../vapoursynth/libvapoursynth.4.dylib" "$so_file" 2>/dev/null || true
            # Fix Python library reference (from python-build-standalone's internal path)
            install_name_tool -change "/install/lib/libpython${PYTHON_MAJOR_MINOR}.dylib" \
                "@loader_path/../python/lib/libpython${PYTHON_MAJOR_MINOR}.dylib" "$so_file" 2>/dev/null || true
        fi
    done

    echo "  Fixing library paths..."
    cd "$DEPS_DIR/vapoursynth"

    # Fix all library install names to be relative
    for lib in *.dylib; do
        install_name_tool -id "@loader_path/$lib" "$lib" 2>/dev/null || true
    done

    # Fix vspipe-bin to use relative paths
    install_name_tool -change "$VS_INSTALL_DIR/lib/libvapoursynth-script.4.dylib" \
        "@executable_path/libvapoursynth-script.4.dylib" vspipe-bin

    # Fix libvapoursynth-script references
    install_name_tool -change "$VS_INSTALL_DIR/lib/libvapoursynth.4.dylib" \
        "@loader_path/libvapoursynth.4.dylib" libvapoursynth-script.dylib
    install_name_tool -change "$VS_INSTALL_DIR/lib/libvapoursynth.4.dylib" \
        "@loader_path/libvapoursynth.4.dylib" libvapoursynth-script.4.dylib

    # Fix Python library reference to use our embedded Python
    install_name_tool -change "$PYTHON_DIR/lib/libpython${PYTHON_MAJOR_MINOR}.dylib" \
        "@executable_path/../python/lib/libpython${PYTHON_MAJOR_MINOR}.dylib" libvapoursynth-script.dylib
    install_name_tool -change "$PYTHON_DIR/lib/libpython${PYTHON_MAJOR_MINOR}.dylib" \
        "@executable_path/../python/lib/libpython${PYTHON_MAJOR_MINOR}.dylib" libvapoursynth-script.4.dylib

    # Fix zimg references
    install_name_tool -change "$BREW_PREFIX/opt/zimg/lib/libzimg.2.dylib" \
        "@loader_path/libzimg.dylib" libvapoursynth.dylib
    install_name_tool -change "$BREW_PREFIX/opt/zimg/lib/libzimg.2.dylib" \
        "@loader_path/libzimg.dylib" libvapoursynth.4.dylib

    # Create wrapper script (generates config dynamically with absolute path)
    cat > "$DEPS_DIR/vapoursynth/vspipe" << 'WRAPPER_EOF'
#!/bin/bash
# VapourSynth vspipe wrapper - fully self-contained, no Homebrew dependency
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPS_ROOT="$(dirname "$SCRIPT_DIR")"

# Use our embedded Python
export PATH="$DEPS_ROOT/python/bin:$PATH"
export PYTHONHOME="$DEPS_ROOT/python"

# Set plugin path to our bundled plugins
export VAPOURSYNTH_PLUGIN_PATH="$SCRIPT_DIR/plugins"

# Set Python path to load our vapoursynth module and packages
export PYTHONPATH="$DEPS_ROOT/python-packages:${PYTHONPATH:-}"

# Add our lib directories to dylib search path
export DYLD_LIBRARY_PATH="$SCRIPT_DIR:$DEPS_ROOT/python/lib:${DYLD_LIBRARY_PATH:-}"

# Generate config dynamically with correct absolute path
CONF_FILE=$(mktemp)
cat > "$CONF_FILE" << EOF
UserPluginDir=$SCRIPT_DIR/plugins
AutoloadUserPluginDir=true
AutoloadSystemPluginDir=false
EOF
export VAPOURSYNTH_CONF_PATH="$CONF_FILE"

# Run vspipe and clean up config
"$SCRIPT_DIR/vspipe-bin" "$@"
EXIT_CODE=$?
rm -f "$CONF_FILE"
exit $EXIT_CODE
WRAPPER_EOF
    chmod +x "$DEPS_DIR/vapoursynth/vspipe"

    # Create fallback config file (used if wrapper doesn't generate one)
    cat > "$DEPS_DIR/vapoursynth/vapoursynth.conf" << 'CONF_EOF'
AutoloadUserPluginDir=false
AutoloadSystemPluginDir=false
CONF_EOF

    cd "$BUILD_DIR"
    echo "  Built VapourSynth from source with embedded Python"
else
    echo "  VapourSynth already built, skipping"
fi

# ============================================================================
# Copy FFmpeg
# ============================================================================
echo ""
echo "=== Copying FFmpeg ==="
cp "$BREW_PREFIX/bin/ffmpeg" "$DEPS_DIR/ffmpeg/"
cp "$BREW_PREFIX/bin/ffprobe" "$DEPS_DIR/ffmpeg/"
chmod +x "$DEPS_DIR/ffmpeg/ffmpeg" "$DEPS_DIR/ffmpeg/ffprobe"
echo "  Copied FFmpeg"

# ============================================================================
# Copy FFMS2 plugin
# ============================================================================
echo ""
echo "=== Copying FFMS2 plugin ==="
if [ -f "$BREW_PREFIX/lib/libffms2.dylib" ]; then
    cp "$BREW_PREFIX/lib/libffms2.dylib" "$PLUGINS_DIR/"
    echo "  Copied FFMS2 plugin"
fi

# ============================================================================
# Copy FFTW library
# ============================================================================
echo ""
echo "=== Copying FFTW library ==="
if [ -f "$BREW_PREFIX/lib/libfftw3f.dylib" ]; then
    cp "$BREW_PREFIX/lib/libfftw3f.dylib" "$DEPS_DIR/vapoursynth/"
    cp "$BREW_PREFIX/lib/libfftw3f.3.dylib" "$DEPS_DIR/vapoursynth/" 2>/dev/null || true
    echo "  Copied FFTW"
fi

# ============================================================================
# Build plugins from source
# ============================================================================
cd "$BUILD_DIR"

# Track what we've built
BUILT_PLUGINS=()
FAILED_PLUGINS=()

build_plugin() {
    local name="$1"
    local repo="$2"
    local output_lib="$3"
    local build_cmd="$4"

    if [ "$FORCE" = false ] && [ -f "$PLUGINS_DIR/$output_lib" ]; then
        echo "  $name already exists, skipping"
        return 0
    fi

    echo ""
    echo "=== Building $name ==="

    rm -rf "$name"
    if ! git clone --depth 1 "$repo" "$name" 2>/dev/null; then
        echo "  Failed to clone $name"
        FAILED_PLUGINS+=("$name")
        return 1
    fi

    cd "$name"

    if eval "$build_cmd"; then
        # Find the built library
        local lib_path=$(find . -name "*.dylib" -type f 2>/dev/null | head -1)
        if [ -n "$lib_path" ]; then
            cp "$lib_path" "$PLUGINS_DIR/$output_lib"
            echo "  Built $name -> $output_lib"
            BUILT_PLUGINS+=("$name")
        else
            echo "  Warning: No .dylib found for $name"
            FAILED_PLUGINS+=("$name")
        fi
    else
        echo "  Failed to build $name"
        FAILED_PLUGINS+=("$name")
    fi

    cd "$BUILD_DIR"
}

# MVTools (essential for QTGMC motion compensation)
build_plugin "mvtools" \
    "https://github.com/dubhater/vapoursynth-mvtools.git" \
    "libmvtools.dylib" \
    "meson setup build --buildtype=release && ninja -C build"

# ZNEDI3 (neural network interpolation - primary for QTGMC)
echo ""
echo "=== Building ZNEDI3 ==="
if [ "$FORCE" = true ] || [ ! -f "$PLUGINS_DIR/libznedi3.dylib" ]; then
    rm -rf znedi3
    git clone --depth 1 https://github.com/sekrit-twc/znedi3.git znedi3
    cd znedi3
    # ZNEDI3 has its own makefile - need to disable x86 optimizations on arm64
    if [ "$ARCH" = "arm64" ]; then
        make X86=0 X86_AVX512=0 -j$(sysctl -n hw.ncpu) 2>/dev/null || make -j$(sysctl -n hw.ncpu)
    else
        make -j$(sysctl -n hw.ncpu)
    fi
    # Find the output
    if [ -f "vsznedi3.dylib" ]; then
        cp vsznedi3.dylib "$PLUGINS_DIR/libznedi3.dylib"
    elif [ -f "vsznedi3.so" ]; then
        cp vsznedi3.so "$PLUGINS_DIR/libznedi3.dylib"
    else
        find . -name "*.dylib" -o -name "*.so" | head -1 | xargs -I {} cp {} "$PLUGINS_DIR/libznedi3.dylib" 2>/dev/null || echo "  ZNEDI3 build failed"
    fi
    # Copy weights
    [ -f "nnedi3_weights.bin" ] && cp nnedi3_weights.bin "$PLUGINS_DIR/"
    cd "$BUILD_DIR"
    echo "  Built ZNEDI3"
else
    echo "  ZNEDI3 already exists, skipping"
fi

# NNEDI3 (CPU version)
build_plugin "nnedi3" \
    "https://github.com/dubhater/vapoursynth-nnedi3.git" \
    "libnnedi3.dylib" \
    "./autogen.sh && ./configure && make -j\$(sysctl -n hw.ncpu) && cp .libs/libnnedi3.dylib . 2>/dev/null || cp src/.libs/libnnedi3.dylib . 2>/dev/null"

# NNEDI3CL (OpenCL version)
build_plugin "nnedi3cl" \
    "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-NNEDI3CL.git" \
    "libnnedi3cl.dylib" \
    "meson setup build --buildtype=release && ninja -C build"

# EEDI3m (edge-directed interpolation)
build_plugin "eedi3m" \
    "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-EEDI3.git" \
    "libeedi3m.dylib" \
    "meson setup build --buildtype=release && ninja -C build"

# fmtconv (format conversion)
echo ""
echo "=== Building fmtconv ==="
if [ "$FORCE" = true ] || [ ! -f "$PLUGINS_DIR/libfmtconv.dylib" ]; then
    rm -rf fmtconv
    git clone --depth 1 https://github.com/EleonoreMizo/fmtconv.git fmtconv
    cd fmtconv/build/unix
    ./autogen.sh
    ./configure
    make -j$(sysctl -n hw.ncpu)
    cp .libs/libfmtconv.dylib "$PLUGINS_DIR/" 2>/dev/null || \
        find ../.. -name "libfmtconv*.dylib" | head -1 | xargs -I {} cp {} "$PLUGINS_DIR/libfmtconv.dylib"
    cd "$BUILD_DIR"
    echo "  Built fmtconv"
else
    echo "  fmtconv already exists, skipping"
fi

# DFTTest (FFT-based denoising)
build_plugin "dfttest" \
    "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-DFTTest.git" \
    "libdfttest.dylib" \
    "meson setup build --buildtype=release && ninja -C build"

# FFT3DFilter
build_plugin "fft3dfilter" \
    "https://github.com/myrsloik/VapourSynth-FFT3DFilter.git" \
    "libfft3dfilter.dylib" \
    "meson setup build --buildtype=release && ninja -C build"

# MiscFilters
build_plugin "miscfilters" \
    "https://github.com/vapoursynth/vs-miscfilters-obsolete.git" \
    "libmiscfilters.dylib" \
    "meson setup build --buildtype=release && ninja -C build"

# RemoveGrain
build_plugin "removegrain" \
    "https://github.com/vapoursynth/vs-removegrain.git" \
    "libremovegrain.dylib" \
    "meson setup build --buildtype=release && ninja -C build"

# AddGrain
build_plugin "addgrain" \
    "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-AddGrain.git" \
    "libaddgrain.dylib" \
    "meson setup build --buildtype=release && ninja -C build"

# neo-f3kdb (debanding)
echo ""
echo "=== Building neo-f3kdb ==="
if [ "$FORCE" = true ] || [ ! -f "$PLUGINS_DIR/libf3kdb.dylib" ]; then
    rm -rf f3kdb
    git clone --depth 1 https://github.com/HomeOfAviSynthPlusEvolution/neo_f3kdb.git f3kdb
    cd f3kdb
    cmake -B build -S . -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$ARCH"
    cmake --build build --config Release
    find build -name "*.dylib" | head -1 | xargs -I {} cp {} "$PLUGINS_DIR/libf3kdb.dylib"
    cd "$BUILD_DIR"
    echo "  Built neo-f3kdb"
else
    echo "  neo-f3kdb already exists, skipping"
fi

# CAS (Contrast Adaptive Sharpening)
build_plugin "cas" \
    "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-CAS.git" \
    "libcas.dylib" \
    "meson setup build --buildtype=release && ninja -C build"

# DCTFilter
build_plugin "dctfilter" \
    "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-DCTFilter.git" \
    "libdctfilter.dylib" \
    "meson setup build --buildtype=release && ninja -C build"

# Deblock
build_plugin "deblock" \
    "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-Deblock.git" \
    "libdeblock.dylib" \
    "meson setup build --buildtype=release && ninja -C build"

# AWarpSharp2
build_plugin "awarpsharp2" \
    "https://github.com/dubhater/vapoursynth-awarpsharp2.git" \
    "libawarpsharp2.dylib" \
    "meson setup build --buildtype=release && ninja -C build"

# CTMF (Constant Time Median Filter)
build_plugin "ctmf" \
    "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-CTMF.git" \
    "libctmf.dylib" \
    "meson setup build --buildtype=release && ninja -C build"

# TCanny (edge detection)
build_plugin "tcanny" \
    "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-TCanny.git" \
    "libtcanny.dylib" \
    "meson setup build --buildtype=release && ninja -C build"

# BM3D
build_plugin "bm3d" \
    "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-BM3D.git" \
    "libbm3d.dylib" \
    "meson setup build --buildtype=release && ninja -C build"

# KNLMeansCL (OpenCL denoiser)
build_plugin "knlmeanscl" \
    "https://github.com/Khanattila/KNLMeansCL.git" \
    "libknlmeanscl.dylib" \
    "meson setup build --buildtype=release && ninja -C build"

# ============================================================================
# Download NNEDI3 weights
# ============================================================================
echo ""
echo "=== Downloading NNEDI3 weights ==="
if [ ! -f "$PLUGINS_DIR/nnedi3_weights.bin" ]; then
    curl -L -o "$PLUGINS_DIR/nnedi3_weights.bin" \
        "https://github.com/sekrit-twc/znedi3/raw/master/nnedi3_weights.bin"
    echo "  Downloaded nnedi3_weights.bin"
fi
cp "$PLUGINS_DIR/nnedi3_weights.bin" "$DEPS_DIR/resources/NNEDI3CL/" 2>/dev/null || true

# ============================================================================
# Download Python packages
# ============================================================================
echo ""
echo "=== Downloading Python packages ==="

# havsfunc
HAVSFUNC_URL="https://github.com/HomeOfVapourSynthEvolution/havsfunc/archive/refs/tags/r31.tar.gz"
if [ "$FORCE" = true ] || [ ! -f "$PYTHON_PACKAGES_DIR/havsfunc.py" ]; then
    curl -L -o /tmp/havsfunc.tar.gz "$HAVSFUNC_URL"
    tar -xzf /tmp/havsfunc.tar.gz -C /tmp
    cp /tmp/havsfunc-r31/havsfunc.py "$PYTHON_PACKAGES_DIR/"
    rm -rf /tmp/havsfunc.tar.gz /tmp/havsfunc-r31
    echo "  Downloaded havsfunc.py"
fi

# mvsfunc
if [ "$FORCE" = true ] || [ ! -d "$PYTHON_PACKAGES_DIR/mvsfunc" ]; then
    curl -L -o /tmp/mvsfunc.zip "https://github.com/HomeOfVapourSynthEvolution/mvsfunc/archive/refs/heads/master.zip"
    unzip -q /tmp/mvsfunc.zip -d /tmp
    cp -r /tmp/mvsfunc-master/mvsfunc "$PYTHON_PACKAGES_DIR/"
    rm -rf /tmp/mvsfunc.zip /tmp/mvsfunc-master
    echo "  Downloaded mvsfunc"
fi

# adjust
if [ "$FORCE" = true ] || [ ! -f "$PYTHON_PACKAGES_DIR/adjust.py" ]; then
    curl -L -o "$PYTHON_PACKAGES_DIR/adjust.py" \
        "https://raw.githubusercontent.com/dubhater/vapoursynth-adjust/master/adjust.py" 2>/dev/null || true
    echo "  Downloaded adjust.py"
fi

# ============================================================================
# Patch havsfunc for API compatibility
# ============================================================================
echo ""
echo "=== Patching havsfunc ==="

HAVSFUNC="$PYTHON_PACKAGES_DIR/havsfunc.py"
if [ -f "$HAVSFUNC" ]; then
    python3 << 'EOF'
import re
import sys
import os

havsfunc_path = os.environ.get('HAVSFUNC_PATH', '')
if not havsfunc_path:
    print("  Error: HAVSFUNC_PATH not set")
    sys.exit(1)

with open(havsfunc_path, 'r') as f:
    content = f.read()

patches = []

# Patch 1: mvtools API
if '_fix_mv_args' not in content:
    patch_func = '''

# Compatibility patch for mvtools API
def _fix_mv_args(args):
    result = {}
    for k, v in args.items():
        if k == '_lambda':
            result['lambda'] = v
        elif k == '_global':
            result['global'] = v
        else:
            result[k] = v
    return result
'''
    content = content.replace('import math\n', 'import math\n' + patch_func)
    content = content.replace('**analyse_args)', '**_fix_mv_args(analyse_args))')
    content = content.replace('**recalculate_args)', '**_fix_mv_args(recalculate_args))')
    patches.append('mvtools API')

# Patch 2: DFTTest API
if "sstring='0.0:4.0 0.2:9.0 1.0:15.0'" in content:
    content = content.replace("sstring='0.0:4.0 0.2:9.0 1.0:15.0'", "sigma=10.0")
    patches.append('DFTTest API')

# Patch 3: YCOCG removal
if 'vs.YCOCG' in content:
    content = content.replace(
        "input.format.color_family not in [vs.YUV, vs.YCOCG]",
        "input.format.color_family != vs.YUV"
    )
    content = content.replace(
        "'LUTDeCrawl: This is not an 8-10 bit YUV or YCoCg clip'",
        "'LUTDeCrawl: This is not an 8-10 bit YUV clip'"
    )
    patches.append('YCOCG')

if patches:
    with open(havsfunc_path, 'w') as f:
        f.write(content)
    print(f"  Patched: {', '.join(patches)}")
else:
    print("  Already patched")
EOF
fi

# ============================================================================
# Sign all binaries and libraries (required for macOS code signing)
# ============================================================================
echo ""
echo "=== Signing binaries and libraries ==="

# Sign Python library
codesign -s - -f "$PYTHON_DIR/lib/libpython${PYTHON_MAJOR_MINOR}.dylib" 2>/dev/null && echo "  Signed Python library"

# Sign VapourSynth components
cd "$DEPS_DIR/vapoursynth"
for lib in *.dylib vspipe-bin; do
    if [ -f "$lib" ]; then
        codesign -s - -f "$lib" 2>/dev/null && echo "  Signed $lib"
    fi
done

# Sign all plugins
cd "$PLUGINS_DIR"
for plugin in *.dylib; do
    if [ -f "$plugin" ]; then
        codesign -s - -f "$plugin" 2>/dev/null && echo "  Signed plugin: $plugin"
    fi
done

# Sign Python module
cd "$PYTHON_PACKAGES_DIR"
for so_file in vapoursynth.cpython-*.so; do
    if [ -f "$so_file" ]; then
        codesign -s - -f "$so_file" 2>/dev/null && echo "  Signed $so_file"
    fi
done

cd "$BUILD_DIR"

# ============================================================================
# Write version file
# ============================================================================
echo ""
echo "=== Writing version file ==="

cat > "$DEPS_DIR/version.json" << EOF
{
  "version": "1.0.0",
  "installedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "platform": "$PLATFORM_DIR",
  "architecture": "$ARCH",
  "buildType": "source"
}
EOF

# ============================================================================
# Cleanup
# ============================================================================
echo ""
echo "=== Cleaning up ==="
rm -rf "$BUILD_DIR"

# ============================================================================
# Verify installation
# ============================================================================
echo ""
echo "=== Verification ==="

echo "Plugin architectures:"
for plugin in "$PLUGINS_DIR"/*.dylib; do
    if [ -f "$plugin" ]; then
        arch=$(file "$plugin" | grep -oE '(x86_64|arm64)' | head -1)
        name=$(basename "$plugin")
        if [ "$arch" = "$ARCH" ] || [ "$arch" = "arm64" -a "$ARCH" = "arm64" ]; then
            echo "  ✓ $name: $arch"
        else
            echo "  ✗ $name: $arch (WRONG ARCH!)"
        fi
    fi
done

echo ""
echo "vspipe architecture:"
file "$DEPS_DIR/vapoursynth/vspipe"

echo ""
echo "=== Summary ==="
PLUGIN_COUNT=$(ls -1 "$PLUGINS_DIR"/*.dylib 2>/dev/null | wc -l | tr -d ' ')
echo "Total plugins: $PLUGIN_COUNT"

if [ ${#FAILED_PLUGINS[@]} -gt 0 ]; then
    echo ""
    echo "Failed plugins: ${FAILED_PLUGINS[*]}"
fi

echo ""
echo "Installation complete: $DEPS_DIR"
echo ""
echo "To test:"
echo "  VAPOURSYNTH_PLUGIN_PATH='$PLUGINS_DIR' \\"
echo "  PYTHONPATH='$PYTHON_PACKAGES_DIR' \\"
echo "  '$DEPS_DIR/vapoursynth/vspipe' --version"
