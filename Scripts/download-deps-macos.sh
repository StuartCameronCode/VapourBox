#!/bin/bash
# Download and build dependencies for VapourBox on macOS (native arm64/x64)
# Builds VapourSynth plugins from source for native architecture support
# Creates a fully self-contained app with no Homebrew runtime dependencies
#
# Pre-built ARM64 plugins sourced from:
# - yuygfgg/Macos_vapoursynth_plugins (https://github.com/yuygfgg/Macos_vapoursynth_plugins)
#   - neo_f3kdb, dfttest, fftw libraries
# - Stefan-Olt/vs-plugin-build (https://github.com/Stefan-Olt/vs-plugin-build)
#   - pipe_source.py (raw frame reader for VapourSynth)
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

# NOTE: x64 deps are built natively on an Intel Mac / the macos-15-intel CI
# runner (uname -m reports x86_64 -> macos-x64). To build x64 deps on an Apple
# Silicon Mac instead, run this script translated through Rosetta 2 with an
# Intel Homebrew prefix first in PATH, e.g.:
#   arch -x86_64 /bin/bash -lc 'PATH=/usr/local/bin:$PATH ./Scripts/download-deps-macos.sh --force'

# ============================================================================
# Minimum macOS deployment target (issue #39) — x64 / Intel only
# ============================================================================
# These deps are compiled on the newest available runner (macos-15 / Sequoia).
# Without pinning a deployment target, clang/meson/cmake default to the host SDK
# (minos 15.0) and the binaries link against libc++ / libSystem symbols that do
# not exist on older macOS. That is exactly the "dyld: Symbol not found" crash
# loading vspipe-bin reported on Monterey 12.7.6.
#
# We only commit to back-deploying the **Intel (x64)** bundle, since that is what
# the Monterey-era machines in the field run. Apple Silicon (arm64) is left
# unchanged: its hardware floor is Big Sur 11, those Macs get modern macOS, and
# there is no old arm64 runner to source older Homebrew bottles from anyway.
#
# Exporting MACOSX_DEPLOYMENT_TARGET makes every from-source build (clang's
# -mmacosx-version-min, meson's auto-detection, and CMake's CMAKE_OSX_DEPLOYMENT_TARGET
# fallback) target this floor. Override with $MACOS_MIN_VERSION if needed.
# NOTE: this does NOT retarget prebuilt artifacts the script merely copies
# (Homebrew bottles, evermeet ffmpeg, python-build-standalone, Stefan-Olt plugins) —
# the minos verification guard near the end of this script reports those.
if [ "$ARCH" = "x86_64" ]; then
    MACOS_MIN_VERSION="${MACOS_MIN_VERSION:-12.0}"   # Monterey
    export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN_VERSION"
    # CMake honors the env var as a fallback, but some plugin CMakeLists set their
    # own target; pass it explicitly on the cmake lines too (see neo-f3kdb).
    export CMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN_VERSION"
    echo "Minimum macOS deployment target (x64): $MACOS_MIN_VERSION (override via \$MACOS_MIN_VERSION)"
else
    echo "arm64 build: not pinning a deployment target (Intel-only back-deploy)"
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
mkdir -p "$DEPS_DIR"/{vapoursynth,ffmpeg,python,python-packages,lib,resources/NNEDI3CL}
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
    zimg
    # Support libraries bundled into deps/.../lib (copied, not linked from homebrew):
    #   fftw       -> libfftw3f.3 + libfftw3f_threads.3 (dfttest)
    #   boost      -> libboost_filesystem + libboost_atomic (nnedi3cl)
    #   libdvdread -> libdvdread (DVD title extraction in the worker)
    #   xz         -> liblzma.5 (linked by Stefan-Olt's x86_64 bestsource)
    fftw boost libdvdread xz
    # FFmpeg (build-time convenience only; at runtime both arches ship static
    # ffmpeg downloaded from evermeet.cx (x64) / martin-riedl.de (arm64))
    ffmpeg
)

for dep in "${BREW_DEPS[@]}"; do
    if brew list "$dep" &>/dev/null; then
        echo "  $dep already installed"
        continue
    fi
    echo "Installing $dep..."
    # Tolerate `brew link` conflicts: a build tool (e.g. meson) can pull in
    # python as a dependency that fails to symlink into /usr/local/bin because
    # the CI runner already has a Python.framework linked there. brew then exits
    # non-zero even though the formula installed fine, which would abort `set -e`.
    # We don't use brew's python (an embedded python-build-standalone is used),
    # so verify the formula actually installed rather than trusting the exit code.
    brew install "$dep" || true
    if ! brew list "$dep" &>/dev/null; then
        echo "ERROR: failed to install Homebrew dependency: $dep" >&2
        exit 1
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

    # ------------------------------------------------------------------------
    # Back-deploy patch for Monterey (issue #39) — x64 only
    # ------------------------------------------------------------------------
    # vspipe's doubleToString() (in src/vspipe/vsjson.cpp and src/vspipe/vspipe.cpp)
    # uses std::to_chars(double), whose libc++ implementation was introduced in
    # macOS 13.3. Built against a 12.0 deployment target the SDK rejects it
    # ('to_chars is unavailable: introduced in macOS 13.3'); shipped from a 15.0
    # build it links a libc++ symbol absent on Monterey -> the "dyld: Symbol not
    # found" crash in #39. Rewrite it to emit the shortest round-tripping fixed
    # string via snprintf, which back-deploys cleanly. x64 only so the arm64
    # bundle stays byte-for-byte unchanged.
    if [ "$ARCH" = "x86_64" ]; then
        echo "  Patching vspipe doubleToString for Monterey back-deploy (issue #39)..."
        for vs_src in src/vspipe/vsjson.cpp src/vspipe/vspipe.cpp; do
            VS_SRC="$vs_src" python3 - <<'PYEOF'
import os, sys
path = os.environ["VS_SRC"]
with open(path) as f:
    content = f.read()

old = ("    auto res = std::to_chars(buffer, buffer + sizeof(buffer), v, std::chars_format::fixed);\n"
       "    return std::string(buffer, res.ptr - buffer);")
new = ("    // issue #39: std::to_chars(double) needs macOS 13.3+ libc++. Emit the\n"
       "    // shortest fixed-notation string that round-trips, via snprintf, so\n"
       "    // vspipe loads on Monterey 12.x.\n"
       "    for (int prec = 0; prec <= 17; ++prec) {\n"
       "        std::snprintf(buffer, sizeof(buffer), \"%.*f\", prec, v);\n"
       "        if (std::strtod(buffer, nullptr) == v)\n"
       "            return std::string(buffer);\n"
       "    }\n"
       "    std::snprintf(buffer, sizeof(buffer), \"%.17f\", v);\n"
       "    return std::string(buffer);")

if old not in content:
    if "issue #39" in content:
        print(f"    {path}: already patched")
        sys.exit(0)
    print(f"    ERROR: expected to_chars pattern not found in {path}", file=sys.stderr)
    sys.exit(1)

content = content.replace(old, new)
# Ensure the headers snprintf/strtod need are present (idempotent).
content = content.replace("#include <charconv>\n",
                          "#include <charconv>\n#include <cstdio>\n#include <cstdlib>\n", 1)
with open(path, "w") as f:
    f.write(content)
print(f"    Patched {path}")
PYEOF
        done
    fi

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
# FFmpeg
# ============================================================================
echo ""
echo "=== Installing FFmpeg ==="
if [ "$ARCH" = "x86_64" ]; then
    # evermeet.cx ships static x86_64 ffmpeg/ffprobe that link only system
    # frameworks (verified self-contained), so no dylib wrangling is needed.
    # This is the canonical pre-built source for Intel macOS ffmpeg.
    echo "  Downloading static x86_64 FFmpeg from evermeet.cx..."
    curl -sL "https://evermeet.cx/ffmpeg/getrelease/ffmpeg/zip" -o "$BUILD_DIR/ffmpeg.zip"
    curl -sL "https://evermeet.cx/ffmpeg/getrelease/ffprobe/zip" -o "$BUILD_DIR/ffprobe.zip"
    unzip -q -o "$BUILD_DIR/ffmpeg.zip" -d "$DEPS_DIR/ffmpeg/"
    unzip -q -o "$BUILD_DIR/ffprobe.zip" -d "$DEPS_DIR/ffmpeg/"
    chmod +x "$DEPS_DIR/ffmpeg/ffmpeg" "$DEPS_DIR/ffmpeg/ffprobe"
    codesign -s - -f "$DEPS_DIR/ffmpeg/ffmpeg" 2>/dev/null || true
    codesign -s - -f "$DEPS_DIR/ffmpeg/ffprobe" 2>/dev/null || true
    echo "  Installed evermeet.cx FFmpeg"
else
    # arm64: Homebrew's ffmpeg is dynamically linked against ~17 Homebrew dylibs
    # (/opt/homebrew/Cellar/ffmpeg/.../lib*, x264, x265, dav1d, openssl, ...), so
    # copying just the binary yields a bundle that won't run on users' Macs.
    # Use the static arm64 build from martin-riedl.de (links only system
    # frameworks, ~60 MB) - the same source the 1.3.0 deps shipped, and the
    # arm64 analogue of the evermeet.cx static build used for x64 above.
    echo "  Downloading static arm64 FFmpeg from martin-riedl.de..."
    curl -sL "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffmpeg.zip" -o "$BUILD_DIR/ffmpeg.zip"
    curl -sL "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffprobe.zip" -o "$BUILD_DIR/ffprobe.zip"
    unzip -q -o "$BUILD_DIR/ffmpeg.zip" -d "$DEPS_DIR/ffmpeg/"
    unzip -q -o "$BUILD_DIR/ffprobe.zip" -d "$DEPS_DIR/ffmpeg/"
    chmod +x "$DEPS_DIR/ffmpeg/ffmpeg" "$DEPS_DIR/ffmpeg/ffprobe"
    codesign -s - -f "$DEPS_DIR/ffmpeg/ffmpeg" 2>/dev/null || true
    codesign -s - -f "$DEPS_DIR/ffmpeg/ffprobe" 2>/dev/null || true
    echo "  Installed static arm64 FFmpeg from martin-riedl.de"
fi

# ============================================================================
# Download pre-built plugins from yuygfgg/Macos_vapoursynth_plugins (ARM64)
# These are optimized ARM64 builds that work better than building from source
# ============================================================================
echo ""
echo "=== Downloading pre-built ARM64 plugins ==="

YUYGFGG_BASE="https://github.com/yuygfgg/Macos_vapoursynth_plugins/raw/main"
LIB_DIR="$DEPS_DIR/lib"
mkdir -p "$LIB_DIR"

if [ "$ARCH" = "arm64" ]; then
    # Download optimized ARM64 plugins from yuygfgg
    echo "  Downloading from yuygfgg/Macos_vapoursynth_plugins..."

    # FFTW libraries (required for dfttest)
    curl -sL "$YUYGFGG_BASE/support/libfftw3f.3.dylib" -o "$LIB_DIR/libfftw3f.3.dylib"
    curl -sL "$YUYGFGG_BASE/support/libfftw3f_threads.3.dylib" -o "$LIB_DIR/libfftw3f_threads.3.dylib"

    # Fix library paths
    install_name_tool -id "@loader_path/libfftw3f.3.dylib" "$LIB_DIR/libfftw3f.3.dylib"
    install_name_tool -id "@loader_path/libfftw3f_threads.3.dylib" "$LIB_DIR/libfftw3f_threads.3.dylib"
    install_name_tool -change "@rpath/libfftw3f.3.dylib" "@loader_path/libfftw3f.3.dylib" "$LIB_DIR/libfftw3f_threads.3.dylib"

    # Sign libraries
    codesign -s - -f "$LIB_DIR/libfftw3f.3.dylib" 2>/dev/null
    codesign -s - -f "$LIB_DIR/libfftw3f_threads.3.dylib" 2>/dev/null

    # Boost libraries (required by NNEDI3CL)
    echo "  Copying Boost libraries for NNEDI3CL..."
    cp "$BREW_PREFIX/lib/libboost_filesystem.dylib" "$LIB_DIR/"
    cp "$BREW_PREFIX/lib/libboost_atomic.dylib" "$LIB_DIR/"
    install_name_tool -id "@loader_path/libboost_filesystem.dylib" "$LIB_DIR/libboost_filesystem.dylib"
    install_name_tool -id "@loader_path/libboost_atomic.dylib" "$LIB_DIR/libboost_atomic.dylib"
    install_name_tool -change "$BREW_PREFIX/opt/boost/lib/libboost_atomic.dylib" "@loader_path/libboost_atomic.dylib" "$LIB_DIR/libboost_filesystem.dylib"
    codesign -s - -f "$LIB_DIR/libboost_filesystem.dylib" 2>/dev/null
    codesign -s - -f "$LIB_DIR/libboost_atomic.dylib" 2>/dev/null

    # neo_f3kdb (optimized ARM64 build)
    curl -sL "$YUYGFGG_BASE/lib/libneo-f3kdb.dylib" -o "$PLUGINS_DIR/libneo-f3kdb.dylib"
    install_name_tool -id "@loader_path/libneo-f3kdb.dylib" "$PLUGINS_DIR/libneo-f3kdb.dylib"
    codesign -s - -f "$PLUGINS_DIR/libneo-f3kdb.dylib" 2>/dev/null

    # dfttest (with proper FFTW support)
    curl -sL "$YUYGFGG_BASE/lib/libdfttest.dylib" -o "$PLUGINS_DIR/libdfttest.dylib"
    install_name_tool -change "@rpath/libfftw3f.3.dylib" "@loader_path/../../lib/libfftw3f.3.dylib" "$PLUGINS_DIR/libdfttest.dylib"
    install_name_tool -change "@rpath/libfftw3f_threads.3.dylib" "@loader_path/../../lib/libfftw3f_threads.3.dylib" "$PLUGINS_DIR/libdfttest.dylib"
    codesign -s - -f "$PLUGINS_DIR/libdfttest.dylib" 2>/dev/null

    # TTempSmooth (core.ttmpsm.TTempSmooth - used by havsfunc MCTemporalDenoise)
    curl -sL "$YUYGFGG_BASE/lib/libttempsmooth.dylib" -o "$PLUGINS_DIR/libttempsmooth.dylib"
    install_name_tool -id "@loader_path/libttempsmooth.dylib" "$PLUGINS_DIR/libttempsmooth.dylib" 2>/dev/null || true
    codesign -s - -f "$PLUGINS_DIR/libttempsmooth.dylib" 2>/dev/null

    # FFT3DFilter (also used by MCTemporalDenoise; links FFTW like dfttest)
    curl -sL "$YUYGFGG_BASE/lib/libfft3dfilter.dylib" -o "$PLUGINS_DIR/libfft3dfilter.dylib"
    install_name_tool -change "@rpath/libfftw3f.3.dylib" "@loader_path/../../lib/libfftw3f.3.dylib" "$PLUGINS_DIR/libfft3dfilter.dylib" 2>/dev/null || true
    install_name_tool -change "@rpath/libfftw3f_threads.3.dylib" "@loader_path/../../lib/libfftw3f_threads.3.dylib" "$PLUGINS_DIR/libfft3dfilter.dylib" 2>/dev/null || true
    codesign -s - -f "$PLUGINS_DIR/libfft3dfilter.dylib" 2>/dev/null

    # VIVTC (inverse telecine - VFM + VDecimate)
    curl -sL "$YUYGFGG_BASE/lib/libvivtc.dylib" -o "$PLUGINS_DIR/libvivtc.dylib"
    install_name_tool -id "@loader_path/libvivtc.dylib" "$PLUGINS_DIR/libvivtc.dylib"
    codesign -s - -f "$PLUGINS_DIR/libvivtc.dylib" 2>/dev/null

    echo "  Downloaded pre-built ARM64 plugins from yuygfgg"
else
    # x86_64: no yuygfgg equivalent. Source the support libraries from the
    # (Intel) Homebrew prefix; neo-f3kdb / dfttest / vivtc are built from source
    # below (see the "$ARCH" != "arm64" branches).
    echo "  Sourcing x86_64 support libraries from Homebrew ($BREW_PREFIX)..."

    # FFTW (required for dfttest, which is built from source on x86_64)
    cp "$BREW_PREFIX/lib/libfftw3f.3.dylib" "$LIB_DIR/libfftw3f.3.dylib"
    cp "$BREW_PREFIX/lib/libfftw3f_threads.3.dylib" "$LIB_DIR/libfftw3f_threads.3.dylib"
    install_name_tool -id "@loader_path/libfftw3f.3.dylib" "$LIB_DIR/libfftw3f.3.dylib"
    install_name_tool -id "@loader_path/libfftw3f_threads.3.dylib" "$LIB_DIR/libfftw3f_threads.3.dylib"
    install_name_tool -change "$BREW_PREFIX/opt/fftw/lib/libfftw3f.3.dylib" "@loader_path/libfftw3f.3.dylib" "$LIB_DIR/libfftw3f_threads.3.dylib" 2>/dev/null || true
    codesign -s - -f "$LIB_DIR/libfftw3f.3.dylib" 2>/dev/null
    codesign -s - -f "$LIB_DIR/libfftw3f_threads.3.dylib" 2>/dev/null

    # Boost (required by NNEDI3CL)
    cp "$BREW_PREFIX/lib/libboost_filesystem.dylib" "$LIB_DIR/"
    cp "$BREW_PREFIX/lib/libboost_atomic.dylib" "$LIB_DIR/"
    install_name_tool -id "@loader_path/libboost_filesystem.dylib" "$LIB_DIR/libboost_filesystem.dylib"
    install_name_tool -id "@loader_path/libboost_atomic.dylib" "$LIB_DIR/libboost_atomic.dylib"
    install_name_tool -change "$BREW_PREFIX/opt/boost/lib/libboost_atomic.dylib" "@loader_path/libboost_atomic.dylib" "$LIB_DIR/libboost_filesystem.dylib" 2>/dev/null || true
    codesign -s - -f "$LIB_DIR/libboost_filesystem.dylib" 2>/dev/null
    codesign -s - -f "$LIB_DIR/libboost_atomic.dylib" 2>/dev/null

    echo "  Sourced x86_64 support libraries"
fi

# libdvdread (DVD title extraction in the worker) - sourced from Homebrew for
# both architectures. The worker dynamically loads it from deps/.../lib.
if [ ! -f "$LIB_DIR/libdvdread.dylib" ] && [ -f "$BREW_PREFIX/lib/libdvdread.dylib" ]; then
    echo "  Copying libdvdread..."
    cp "$BREW_PREFIX/lib/libdvdread.dylib" "$LIB_DIR/libdvdread.dylib"
    install_name_tool -id "@loader_path/libdvdread.dylib" "$LIB_DIR/libdvdread.dylib" 2>/dev/null || true
    codesign -s - -f "$LIB_DIR/libdvdread.dylib" 2>/dev/null
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

    # Some plugins' meson.build locates the VapourSynth headers by running
    # `import vapoursynth as vs; print(vs.get_include())` in the host python
    # (e.g. mvtools, bm3d, eedi3m). On a clean build machine the host python has
    # no `vapoursynth` module (the runtime VS module is built against our
    # embedded python, not the host's), so that probe fails. Replace it with the
    # from-source VS include dir - same trick already used for vivtc below.
    if [ -n "$VS_INC_DIR" ] && [ -f meson.build ] && grep -q "import vapoursynth" meson.build; then
        VS_INC_DIR="$VS_INC_DIR" python3 - meson.build <<'PYEOF'
import os, re, sys
path = sys.argv[1]
inc = os.environ["VS_INC_DIR"]
s = open(path).read()
s = re.sub(r"run_command\(.*?\)\.stdout\(\)\.strip\(\)", repr(inc), s, flags=re.S)
open(path, "w").write(s)
PYEOF
    fi

    # Expose the from-source VapourSynth to pkg-config so plugins that use
    # `dependency('vapoursynth')` (removegrain, cas, ...) resolve against our
    # R73 build rather than failing or finding a mismatched system install.
    if PKG_CONFIG_PATH="${VS_PC_DIR:-}:${PKG_CONFIG_PATH:-}" eval "$build_cmd"; then
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

# Download a single pre-built plugin dylib from a Stefan-Olt/vs-plugin-build
# release asset URL, fix its install name and sign it. Non-fatal on failure.
download_prebuilt_plugin() {
    local label="$1"
    local out_name="$2"
    local url="$3"

    if [ "$FORCE" = false ] && [ -f "$PLUGINS_DIR/$out_name" ]; then
        echo "  $label already exists, skipping"
        return 0
    fi

    local tmp="$BUILD_DIR/prebuilt-$out_name"
    rm -rf "$tmp"; mkdir -p "$tmp"
    if curl -sL "$url" -o "$tmp/plugin.zip" && unzip -q -o "$tmp/plugin.zip" -d "$tmp"; then
        local found
        found=$(find "$tmp" -name "*.dylib" -type f 2>/dev/null | head -1)
        if [ -n "$found" ]; then
            cp "$found" "$PLUGINS_DIR/$out_name"
            install_name_tool -id "@loader_path/$out_name" "$PLUGINS_DIR/$out_name" 2>/dev/null || true
            codesign -s - -f "$PLUGINS_DIR/$out_name" 2>/dev/null || true
            echo "  Downloaded pre-built $label"
            return 0
        fi
    fi
    echo "  Warning: failed to fetch pre-built $label"
    FAILED_PLUGINS+=("$label")
    return 1
}

STEFANOLT="https://github.com/Stefan-Olt/vs-plugin-build/releases/download/vsplugin"

# pkg-config dir + header dir of the from-source VapourSynth install. Used by the
# plugin builds on BOTH arches (see build_plugin and the x86_64 source builds):
# the host python has no `vapoursynth` module on a clean runner, so meson plugins
# can't probe it the usual way and must be pointed at these explicitly.
VS_PC_DIR="$VS_INSTALL_DIR/lib/pkgconfig"
VS_INC_DIR="$(dirname "$(find "$VS_INSTALL_DIR/include" -name 'VapourSynth4.h' 2>/dev/null | head -1)")"

if [ "$ARCH" = "x86_64" ]; then
    # ========================================================================
    # x86_64 plugins: download pre-built darwin-x86_64 binaries from
    # Stefan-Olt/vs-plugin-build for everything it ships, and build the four it
    # does NOT ship (neo-f3kdb, nnedi3cl, vivtc, descratch) from source. The
    # clean CI runner has no full VapourSynth dev install, so the from-source
    # path used on arm64 doesn't work here; pre-built is the robust route.
    # Pinned URLs are immutable release assets - to refresh, re-resolve the
    # latest darwin-x86_64 asset for each plugin id.
    # ========================================================================
    echo ""
    echo "=== Downloading pre-built x86_64 plugins (Stefan-Olt/vs-plugin-build) ==="
    download_prebuilt_plugin "MVTools"       "libmvtools.dylib"     "$STEFANOLT/com.nodame.mvtools/v24/darwin-x86_64/2024-09-30T17.08.24%2B00.00Z/MVTools-v24-darwin-x86_64.zip"
    download_prebuilt_plugin "ZNEDI3"        "libznedi3.dylib"      "$STEFANOLT/xxx.abc.znedi3/3bd542a/darwin-x86_64/2026-01-10T23.47.38%2B00.00Z/ZNEDI3-3bd542a-darwin-x86_64.zip"
    download_prebuilt_plugin "EEDI3m"        "libeedi3m.dylib"      "$STEFANOLT/com.holywu.eedi3/r8/darwin-x86_64/2026-01-15T20.48.25%2B00.00Z/EEDI3m-r8-darwin-x86_64.zip"
    download_prebuilt_plugin "fmtconv"       "libfmtconv.dylib"     "$STEFANOLT/fmtconv/git-18a9cecb/darwin-x86_64/2024-10-10T14.48.08%2B00.00Z/fmtconv-git-18a9cecb-darwin-x86_64.zip"
    download_prebuilt_plugin "DFTTest"       "libdfttest.dylib"     "$STEFANOLT/com.holywu.dfttest/git-89034df/darwin-x86_64/2024-10-09T23.03.28%2B00.00Z/DFTTest-git-89034df-darwin-x86_64.zip"
    download_prebuilt_plugin "MiscFilters"   "libmiscfilters.dylib" "$STEFANOLT/com.vapoursynth.misc/git-07e0589/darwin-x86_64/2024-10-09T22.52.15%2B00.00Z/Miscfilters-git-07e0589-darwin-x86_64.zip"
    download_prebuilt_plugin "RemoveGrain"   "libremovegrain.dylib" "$STEFANOLT/com.vapoursynth.removegrainvs/git-89ca38a/darwin-x86_64/2024-10-09T22.52.26%2B00.00Z/RemoveGrain-git-89ca38a-darwin-x86_64.zip"
    download_prebuilt_plugin "AddGrain"      "libaddgrain.dylib"    "$STEFANOLT/com.holywu.addgrain/r10/darwin-x86_64/2024-09-30T20.56.34%2B00.00Z/AddGrain-r10-darwin-x86_64.zip"
    download_prebuilt_plugin "CAS"           "libcas.dylib"         "$STEFANOLT/com.holywu.cas/r2/darwin-x86_64/2024-10-01T19.44.56%2B00.00Z/CAS-r2-darwin-x86_64.zip"
    download_prebuilt_plugin "DCTFilter"     "libdctfilter.dylib"   "$STEFANOLT/com.holywu.dctfilter/r2.1/darwin-x86_64/2024-10-09T17.32.30%2B00.00Z/DCTFilter-r2.1-darwin-x86_64.zip"
    download_prebuilt_plugin "Deblock"       "libdeblock.dylib"     "$STEFANOLT/com.holywu.deblock/r7.1/darwin-x86_64/2026-01-06T23.51.04%2B00.00Z/Deblock-r7.1-darwin-x86_64.zip"
    download_prebuilt_plugin "AWarpSharp2"   "libawarpsharp2.dylib" "$STEFANOLT/com.nodame.awarpsharp2/v4/darwin-x86_64/2024-07-22T18.51.03Z/AWarpSharp2-v4-darwin-x86_64.zip"
    download_prebuilt_plugin "CTMF"          "libctmf.dylib"        "$STEFANOLT/com.holywu.ctmf/r5/darwin-x86_64/2024-09-30T20.54.04%2B00.00Z/CTMF-r5-darwin-x86_64.zip"
    download_prebuilt_plugin "TCanny"        "libtcanny.dylib"      "$STEFANOLT/com.holywu.tcanny/r14/darwin-x86_64/2024-09-30T21.00.45%2B00.00Z/TCanny-r14-darwin-x86_64.zip"
    download_prebuilt_plugin "TemporalMedian" "libtmedian.dylib"    "$STEFANOLT/com.nodame.temporalmedian/v1/darwin-x86_64/2024-09-30T21.01.26%2B00.00Z/TemporalMedian-v1-darwin-x86_64.zip"
    download_prebuilt_plugin "BestSource"    "libbestsource.dylib"  "$STEFANOLT/com.vapoursynth.bestsource/R16/darwin-x86_64/2026-01-10T19.07.30%2B00.00Z/BestSource-R16-darwin-x86_64.zip"

    # Stefan-Olt's x86_64 BestSource dynamically links liblzma; bundle it from
    # Homebrew (xz) and repoint the reference at the bundled copy in lib/.
    if [ -f "$PLUGINS_DIR/libbestsource.dylib" ]; then
        if [ ! -f "$LIB_DIR/liblzma.5.dylib" ] && [ -f "$BREW_PREFIX/opt/xz/lib/liblzma.5.dylib" ]; then
            cp "$BREW_PREFIX/opt/xz/lib/liblzma.5.dylib" "$LIB_DIR/liblzma.5.dylib"
            install_name_tool -id "@loader_path/liblzma.5.dylib" "$LIB_DIR/liblzma.5.dylib" 2>/dev/null || true
            codesign -s - -f "$LIB_DIR/liblzma.5.dylib" 2>/dev/null || true
        fi
        install_name_tool -change "$BREW_PREFIX/opt/xz/lib/liblzma.5.dylib" \
            "@loader_path/../../lib/liblzma.5.dylib" "$PLUGINS_DIR/libbestsource.dylib" 2>/dev/null || true
        codesign -s - -f "$PLUGINS_DIR/libbestsource.dylib" 2>/dev/null || true
    fi

    # ---- The four plugins Stefan-Olt does not ship: build from source ----
    cd "$BUILD_DIR"

    # neo-f3kdb (cmake; uses its bundled VapourSynth headers, VCL2 submodule)
    if [ "$FORCE" = true ] || [ ! -f "$PLUGINS_DIR/libneo-f3kdb.dylib" ]; then
        echo ""; echo "=== Building neo-f3kdb (x86_64) ==="
        rm -rf f3kdb
        if git clone --depth 1 --recurse-submodules --shallow-submodules https://github.com/HomeOfAviSynthPlusEvolution/neo_f3kdb.git f3kdb \
           && cmake -S f3kdb -B f3kdb/build -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN_VERSION" \
           && cmake --build f3kdb/build --config Release; then
            lib=$(find f3kdb/build -name "*.dylib" -type f | head -1)
            if [ -n "$lib" ]; then cp "$lib" "$PLUGINS_DIR/libneo-f3kdb.dylib"; echo "  Built neo-f3kdb"; else echo "  no dylib"; FAILED_PLUGINS+=("neo-f3kdb"); fi
        else
            echo "  Failed to build neo-f3kdb"; FAILED_PLUGINS+=("neo-f3kdb")
        fi
        cd "$BUILD_DIR"
    fi

    # nnedi3cl (meson; finds VapourSynth via pkg-config, boost via Homebrew)
    if [ "$FORCE" = true ] || [ ! -f "$PLUGINS_DIR/libnnedi3cl.dylib" ]; then
        echo ""; echo "=== Building NNEDI3CL (x86_64) ==="
        rm -rf nnedi3cl
        if git clone --depth 1 https://github.com/HomeOfVapourSynthEvolution/VapourSynth-NNEDI3CL.git nnedi3cl \
           && PKG_CONFIG_PATH="$VS_PC_DIR:${PKG_CONFIG_PATH:-}" BOOST_ROOT="$BREW_PREFIX" \
              meson setup nnedi3cl/build nnedi3cl --buildtype=release \
           && ninja -C nnedi3cl/build; then
            lib=$(find nnedi3cl/build -name "*.dylib" -type f | head -1)
            if [ -n "$lib" ]; then
                cp "$lib" "$PLUGINS_DIR/libnnedi3cl.dylib"
                # Repoint its Homebrew boost reference at the bundled copy in lib/.
                install_name_tool -change "$BREW_PREFIX/opt/boost/lib/libboost_filesystem.dylib" \
                    "@loader_path/../../lib/libboost_filesystem.dylib" "$PLUGINS_DIR/libnnedi3cl.dylib" 2>/dev/null || true
                codesign -s - -f "$PLUGINS_DIR/libnnedi3cl.dylib" 2>/dev/null || true
                echo "  Built NNEDI3CL"
            else echo "  no dylib"; FAILED_PLUGINS+=("nnedi3cl"); fi
        else
            echo "  Failed to build NNEDI3CL"; FAILED_PLUGINS+=("nnedi3cl")
        fi
        cd "$BUILD_DIR"
    fi

    # vivtc (meson; replace its python get_include() probe with our VS headers)
    if [ "$FORCE" = true ] || [ ! -f "$PLUGINS_DIR/libvivtc.dylib" ]; then
        echo ""; echo "=== Building VIVTC (x86_64) ==="
        rm -rf vivtc
        if git clone --depth 1 https://github.com/vapoursynth/vivtc.git vivtc; then
            VS_INC_DIR="$VS_INC_DIR" python3 - vivtc/meson.build <<'PYEOF'
import os, re, sys
path = sys.argv[1]
inc = os.environ["VS_INC_DIR"]
s = open(path).read()
s = re.sub(r"run_command\(.*?\)\.stdout\(\)\.strip\(\)",
           repr(inc), s, flags=re.S)
open(path, "w").write(s)
PYEOF
            if meson setup vivtc/build vivtc --buildtype=release && ninja -C vivtc/build; then
                lib=$(find vivtc/build -name "*.dylib" -type f | head -1)
                if [ -n "$lib" ]; then cp "$lib" "$PLUGINS_DIR/libvivtc.dylib"; echo "  Built VIVTC"; else echo "  no dylib"; FAILED_PLUGINS+=("vivtc"); fi
            else
                echo "  Failed to build VIVTC"; FAILED_PLUGINS+=("vivtc")
            fi
        else
            echo "  Failed to clone VIVTC"; FAILED_PLUGINS+=("vivtc")
        fi
        cd "$BUILD_DIR"
    fi

    # descratch (meson; uses VapourSynth headers from its own submodule)
    if [ "$FORCE" = true ] || [ ! -f "$PLUGINS_DIR/libdescratch.dylib" ]; then
        echo ""; echo "=== Building DeScratch (x86_64) ==="
        rm -rf descratch
        if git clone --depth 1 --recurse-submodules --shallow-submodules https://github.com/vapoursynth/descratch.git descratch \
           && meson setup descratch/build descratch --buildtype=release \
           && ninja -C descratch/build; then
            lib=$(find descratch/build -name "*.dylib" -type f | head -1)
            if [ -n "$lib" ]; then
                cp "$lib" "$PLUGINS_DIR/libdescratch.dylib"
                install_name_tool -id "@loader_path/libdescratch.dylib" "$PLUGINS_DIR/libdescratch.dylib" 2>/dev/null || true
                echo "  Built DeScratch"
            else
                echo "  no dylib"; FAILED_PLUGINS+=("descratch")
            fi
        else
            echo "  Failed to build DeScratch"; FAILED_PLUGINS+=("descratch")
        fi
        cd "$BUILD_DIR"
    fi

    # ttmpsm (TTempSmooth - meson; finds VapourSynth via pkg-config, no extra deps)
    # Used by havsfunc MCTemporalDenoise.
    if [ "$FORCE" = true ] || [ ! -f "$PLUGINS_DIR/libttempsmooth.dylib" ]; then
        echo ""; echo "=== Building TTempSmooth (x86_64) ==="
        rm -rf ttempsmooth
        if git clone --depth 1 https://github.com/HomeOfVapourSynthEvolution/VapourSynth-TTempSmooth.git ttempsmooth \
           && PKG_CONFIG_PATH="$VS_PC_DIR:${PKG_CONFIG_PATH:-}" \
              meson setup ttempsmooth/build ttempsmooth --buildtype=release \
           && ninja -C ttempsmooth/build; then
            lib=$(find ttempsmooth/build -name "*.dylib" -type f | head -1)
            if [ -n "$lib" ]; then
                cp "$lib" "$PLUGINS_DIR/libttempsmooth.dylib"
                install_name_tool -id "@loader_path/libttempsmooth.dylib" "$PLUGINS_DIR/libttempsmooth.dylib" 2>/dev/null || true
                codesign -s - -f "$PLUGINS_DIR/libttempsmooth.dylib" 2>/dev/null || true
                echo "  Built TTempSmooth"
            else echo "  no dylib"; FAILED_PLUGINS+=("ttempsmooth"); fi
        else
            echo "  Failed to build TTempSmooth"; FAILED_PLUGINS+=("ttempsmooth")
        fi
        cd "$BUILD_DIR"
    fi

    # fft3dfilter (meson; links Homebrew FFTW, repoint at the bundled lib/ copy).
    # Also used by havsfunc MCTemporalDenoise.
    if [ "$FORCE" = true ] || [ ! -f "$PLUGINS_DIR/libfft3dfilter.dylib" ]; then
        echo ""; echo "=== Building FFT3DFilter (x86_64) ==="
        rm -rf fft3dfilter
        if git clone --depth 1 https://github.com/myrsloik/VapourSynth-FFT3DFilter.git fft3dfilter \
           && PKG_CONFIG_PATH="$VS_PC_DIR:$BREW_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}" \
              meson setup fft3dfilter/build fft3dfilter --buildtype=release \
           && ninja -C fft3dfilter/build; then
            lib=$(find fft3dfilter/build -name "*.dylib" -type f | head -1)
            if [ -n "$lib" ]; then
                cp "$lib" "$PLUGINS_DIR/libfft3dfilter.dylib"
                install_name_tool -change "$BREW_PREFIX/opt/fftw/lib/libfftw3f.3.dylib" \
                    "@loader_path/../../lib/libfftw3f.3.dylib" "$PLUGINS_DIR/libfft3dfilter.dylib" 2>/dev/null || true
                install_name_tool -change "$BREW_PREFIX/opt/fftw/lib/libfftw3f_threads.3.dylib" \
                    "@loader_path/../../lib/libfftw3f_threads.3.dylib" "$PLUGINS_DIR/libfft3dfilter.dylib" 2>/dev/null || true
                codesign -s - -f "$PLUGINS_DIR/libfft3dfilter.dylib" 2>/dev/null || true
                echo "  Built FFT3DFilter"
            else echo "  no dylib"; FAILED_PLUGINS+=("fft3dfilter"); fi
        else
            echo "  Failed to build FFT3DFilter"; FAILED_PLUGINS+=("fft3dfilter")
        fi
        cd "$BUILD_DIR"
    fi

    # KNLMeansCL (OpenCL denoiser - core.knlm.KNLMeansCL). Used by QTGMC when its
    # Denoiser is set to "knlmeanscl" (havsfunc). Stefan-Olt doesn't ship an
    # x86_64 build, so build from source like the arm64 path does. Its meson.build
    # needs BOTH the VapourSynth headers (via pkg-config) AND Boost
    # filesystem/system (via Homebrew, same as the nnedi3cl build), so set
    # BOOST_ROOT and defensively repoint any Homebrew boost reference at the
    # bundled copy in lib/ (the arm64 build links boost statically and ends up
    # with no boost dylib reference; the repoints below are no-ops in that case).
    if [ "$FORCE" = true ] || [ ! -f "$PLUGINS_DIR/libknlmeanscl.dylib" ]; then
        echo ""; echo "=== Building KNLMeansCL (x86_64) ==="
        rm -rf knlmeanscl
        if git clone --depth 1 https://github.com/Khanattila/KNLMeansCL.git knlmeanscl \
           && PKG_CONFIG_PATH="$VS_PC_DIR:${PKG_CONFIG_PATH:-}" BOOST_ROOT="$BREW_PREFIX" \
              meson setup knlmeanscl/build knlmeanscl --buildtype=release \
           && ninja -C knlmeanscl/build; then
            lib=$(find knlmeanscl/build -name "*.dylib" -type f | head -1)
            if [ -n "$lib" ]; then
                cp "$lib" "$PLUGINS_DIR/libknlmeanscl.dylib"
                install_name_tool -id "@loader_path/libknlmeanscl.dylib" "$PLUGINS_DIR/libknlmeanscl.dylib" 2>/dev/null || true
                install_name_tool -change "$BREW_PREFIX/opt/boost/lib/libboost_filesystem.dylib" \
                    "@loader_path/../../lib/libboost_filesystem.dylib" "$PLUGINS_DIR/libknlmeanscl.dylib" 2>/dev/null || true
                install_name_tool -change "$BREW_PREFIX/opt/boost/lib/libboost_atomic.dylib" \
                    "@loader_path/../../lib/libboost_atomic.dylib" "$PLUGINS_DIR/libknlmeanscl.dylib" 2>/dev/null || true
                codesign -s - -f "$PLUGINS_DIR/libknlmeanscl.dylib" 2>/dev/null || true
                echo "  Built KNLMeansCL"
            else echo "  no dylib"; FAILED_PLUGINS+=("knlmeanscl"); fi
        else
            echo "  Failed to build KNLMeansCL"; FAILED_PLUGINS+=("knlmeanscl")
        fi
        cd "$BUILD_DIR"
    fi
else
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
    # --recurse-submodules: znedi3 carries graphengine + vsxx (which bundles the
    # VapourSynth headers) as submodules. Without them the build fails with
    # "'znedi3.h' file not found" / missing vsxx4_pluginmain.o.
    git clone --depth 1 --recurse-submodules --shallow-submodules https://github.com/sekrit-twc/znedi3.git znedi3
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
# Its Makefile.am hardcodes `-mfpu=neon` for the NEON path, which clang rejects
# on arm64 ('unsupported option -mfpu='). NEON is baseline on aarch64, so the
# flag isn't needed - strip it before autogen regenerates the Makefiles.
build_plugin "nnedi3" \
    "https://github.com/dubhater/vapoursynth-nnedi3.git" \
    "libnnedi3.dylib" \
    "sed -i '' 's/ -mfpu=neon//' Makefile.am && ./autogen.sh && ./configure && make -j\$(sysctl -n hw.ncpu)"

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
# On ARM64, we use the pre-built version from yuygfgg (downloaded above)
if [ "$ARCH" != "arm64" ]; then
    build_plugin "dfttest" \
        "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-DFTTest.git" \
        "libdfttest.dylib" \
        "meson setup build --buildtype=release && ninja -C build"
else
    echo "  DFTTest: using pre-built ARM64 version from yuygfgg"
fi

# FFT3DFilter
# On ARM64 we use the pre-built version from yuygfgg (downloaded above); its
# from-source build needs fftw3f_threads which isn't reliably discoverable here.
if [ "$ARCH" != "arm64" ]; then
    build_plugin "fft3dfilter" \
        "https://github.com/myrsloik/VapourSynth-FFT3DFilter.git" \
        "libfft3dfilter.dylib" \
        "meson setup build --buildtype=release && ninja -C build"
else
    echo "  FFT3DFilter: using pre-built ARM64 version from yuygfgg"
fi

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

# VIVTC (inverse telecine - VFM + VDecimate)
# On ARM64, we use the pre-built version from yuygfgg (downloaded above)
if [ "$ARCH" != "arm64" ]; then
    build_plugin "vivtc" \
        "https://github.com/vapoursynth/vivtc.git" \
        "libvivtc.dylib" \
        "meson setup build --buildtype=release && ninja -C build"
else
    echo "  VIVTC: using pre-built ARM64 version from yuygfgg"
fi

# neo-f3kdb (debanding)
# On ARM64, we use the pre-built version from yuygfgg (downloaded above)
if [ "$ARCH" != "arm64" ]; then
    echo ""
    echo "=== Building neo-f3kdb ==="
    if [ "$FORCE" = true ] || [ ! -f "$PLUGINS_DIR/libneo-f3kdb.dylib" ]; then
        rm -rf f3kdb
        git clone --depth 1 https://github.com/HomeOfAviSynthPlusEvolution/neo_f3kdb.git f3kdb
        cd f3kdb
        cmake -B build -S . -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN_VERSION"
        cmake --build build --config Release
        find build -name "*.dylib" | head -1 | xargs -I {} cp {} "$PLUGINS_DIR/libneo-f3kdb.dylib"
        cd "$BUILD_DIR"
        echo "  Built neo-f3kdb"
    else
        echo "  neo-f3kdb already exists, skipping"
    fi
else
    echo "  neo_f3kdb: using pre-built ARM64 version from yuygfgg"
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

# DeScratch (vertical scratch removal - core.descratch.DeScratch)
# Built from source: not available pre-built from Stefan-Olt. The repo carries
# the VapourSynth headers as a submodule, so a recursive clone is required.
echo ""
echo "=== Building DeScratch ==="
if [ "$FORCE" = true ] || [ ! -f "$PLUGINS_DIR/libdescratch.dylib" ]; then
    rm -rf descratch
    if git clone --depth 1 --recurse-submodules --shallow-submodules \
        https://github.com/vapoursynth/descratch.git descratch; then
        cd descratch
        if meson setup build --buildtype=release && ninja -C build; then
            lib_path=$(find build -name "*.dylib" -type f 2>/dev/null | head -1)
            if [ -n "$lib_path" ]; then
                cp "$lib_path" "$PLUGINS_DIR/libdescratch.dylib"
                install_name_tool -id "@loader_path/libdescratch.dylib" "$PLUGINS_DIR/libdescratch.dylib" 2>/dev/null || true
                echo "  Built DeScratch"
            else
                echo "  Warning: No .dylib found for DeScratch"
                FAILED_PLUGINS+=("descratch")
            fi
        else
            echo "  Failed to build DeScratch"
            FAILED_PLUGINS+=("descratch")
        fi
        cd "$BUILD_DIR"
    else
        echo "  Failed to clone DeScratch"
        FAILED_PLUGINS+=("descratch")
    fi
else
    echo "  DeScratch already exists, skipping"
fi

# ============================================================================
# Pre-built plugins from Stefan-Olt/vs-plugin-build (both architectures)
# These are not built from source here; Stefan-Olt ships self-contained
# darwin-aarch64 and darwin-x86_64 dylibs. Release assets are immutable, so the
# pinned URLs below are stable - bump the version/timestamp to update.
# ============================================================================
echo ""
echo "=== Downloading pre-built plugins (Stefan-Olt/vs-plugin-build) ==="

download_prebuilt_plugin() {
    local label="$1"
    local out_name="$2"
    local url="$3"

    if [ "$FORCE" = false ] && [ -f "$PLUGINS_DIR/$out_name" ]; then
        echo "  $label already exists, skipping"
        return 0
    fi

    local tmp="$BUILD_DIR/prebuilt-$out_name"
    rm -rf "$tmp"; mkdir -p "$tmp"
    if curl -sL "$url" -o "$tmp/plugin.zip" && unzip -q -o "$tmp/plugin.zip" -d "$tmp"; then
        local found
        found=$(find "$tmp" -name "*.dylib" -type f 2>/dev/null | head -1)
        if [ -n "$found" ]; then
            cp "$found" "$PLUGINS_DIR/$out_name"
            install_name_tool -id "@loader_path/$out_name" "$PLUGINS_DIR/$out_name" 2>/dev/null || true
            codesign -s - -f "$PLUGINS_DIR/$out_name" 2>/dev/null || true
            echo "  Downloaded pre-built $label"
            return 0
        fi
    fi
    echo "  Warning: failed to fetch pre-built $label"
    FAILED_PLUGINS+=("$label")
    return 1
}

STEFANOLT="https://github.com/Stefan-Olt/vs-plugin-build/releases/download/vsplugin"

# TemporalMedian (core.tmedian.TemporalMedian - used by SpotLess)
if [ "$ARCH" = "arm64" ]; then
    TMEDIAN_URL="$STEFANOLT/com.nodame.temporalmedian/v1/darwin-aarch64/2024-09-30T20.56.40%2B00.00Z/TemporalMedian-v1-darwin-aarch64.zip"
else
    TMEDIAN_URL="$STEFANOLT/com.nodame.temporalmedian/v1/darwin-x86_64/2024-09-30T21.01.26%2B00.00Z/TemporalMedian-v1-darwin-x86_64.zip"
fi
download_prebuilt_plugin "TemporalMedian" "libtmedian.dylib" "$TMEDIAN_URL"

# BestSource (core.bs - source loader, bundled for parity)
if [ "$ARCH" = "arm64" ]; then
    BESTSOURCE_URL="$STEFANOLT/com.vapoursynth.bestsource/R16/darwin-aarch64/2026-01-10T18.55.40%2B00.00Z/BestSource-R16-darwin-aarch64.zip"
else
    BESTSOURCE_URL="$STEFANOLT/com.vapoursynth.bestsource/R16/darwin-x86_64/2026-01-10T19.07.30%2B00.00Z/BestSource-R16-darwin-x86_64.zip"
fi
download_prebuilt_plugin "BestSource" "libbestsource.dylib" "$BESTSOURCE_URL"

# Stefan-Olt's aarch64 BestSource links the *system* /usr/lib/liblzma.5.dylib
# (the x86_64 build links Homebrew's xz copy, handled in the x86_64 branch above).
# Bundle liblzma from Homebrew (xz) and repoint the reference at the bundled copy
# so the issue #28 guard stays strict and we don't depend on the system lib.
if [ "$ARCH" = "arm64" ] && [ -f "$PLUGINS_DIR/libbestsource.dylib" ]; then
    if [ ! -f "$LIB_DIR/liblzma.5.dylib" ] && [ -f "$BREW_PREFIX/opt/xz/lib/liblzma.5.dylib" ]; then
        cp "$BREW_PREFIX/opt/xz/lib/liblzma.5.dylib" "$LIB_DIR/liblzma.5.dylib"
        install_name_tool -id "@loader_path/liblzma.5.dylib" "$LIB_DIR/liblzma.5.dylib" 2>/dev/null || true
        codesign -s - -f "$LIB_DIR/liblzma.5.dylib" 2>/dev/null || true
    fi
    install_name_tool -change "/usr/lib/liblzma.5.dylib" \
        "@loader_path/../../lib/liblzma.5.dylib" "$PLUGINS_DIR/libbestsource.dylib" 2>/dev/null || true
    codesign -s - -f "$PLUGINS_DIR/libbestsource.dylib" 2>/dev/null || true
fi
fi  # end plugin arch split (x86_64 pre-built / arm64 from-source)

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
    HAVSFUNC_PATH="$HAVSFUNC" python3 << 'EOF'
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

# Patch 4: EEDI3CL fallback — modern eedi3m plugin removed EEDI3CL (OpenCL).
# When opencl=True, havsfunc tries core.eedi3m.EEDI3CL which doesn't exist.
# Fall back to CPU EEDI3 so opencl mode works (NNEDI3CL still uses GPU).
# Two locations: santiag_stronger (12-space indent) and QTGMC_Interpolate (8-space indent).
# Must patch deeper indent first to avoid substring matches with .replace().
patched_eedi3cl = False

# 4a: santiag_stronger (12-space indent, uses mdis=mdis)
old_santiag = "            myEEDI3 = core.eedi3m.EEDI3CL\n"
if old_santiag in content:
    content = content.replace(
        old_santiag,
        "            has_eedi3cl = hasattr(core, 'eedi3m') and hasattr(core.eedi3m, 'EEDI3CL')\n"
        "            myEEDI3 = core.eedi3m.EEDI3CL if has_eedi3cl else (core.eedi3m.EEDI3 if hasattr(core, 'eedi3m') else core.eedi3.eedi3)\n"
    )
    old_santiag_args = "            eedi3_args = dict(alpha=alpha, beta=beta, gamma=gamma, nrad=nrad, mdis=mdis, vcheck=vcheck, device=device)\n"
    new_santiag_args = "            eedi3_args = dict(alpha=alpha, beta=beta, gamma=gamma, nrad=nrad, mdis=mdis, vcheck=vcheck, device=device) if has_eedi3cl else dict(alpha=alpha, beta=beta, gamma=gamma, nrad=nrad, mdis=mdis, vcheck=vcheck)\n"
    content = content.replace(old_santiag_args, new_santiag_args)
    patched_eedi3cl = True

# 4b: QTGMC_Interpolate (8-space indent, uses mdis=EdiMaxD)
old_qtgmc = "        myEEDI3 = core.eedi3m.EEDI3CL\n"
if old_qtgmc in content:
    content = content.replace(
        old_qtgmc,
        "        has_eedi3cl = hasattr(core, 'eedi3m') and hasattr(core.eedi3m, 'EEDI3CL')\n"
        "        myEEDI3 = core.eedi3m.EEDI3CL if has_eedi3cl else (core.eedi3m.EEDI3 if hasattr(core, 'eedi3m') else core.eedi3.eedi3)\n"
    )
    old_qtgmc_args = "        eedi3_args = dict(alpha=alpha, beta=beta, gamma=gamma, nrad=nrad, mdis=EdiMaxD, vcheck=vcheck, device=device)\n"
    new_qtgmc_args = "        eedi3_args = dict(alpha=alpha, beta=beta, gamma=gamma, nrad=nrad, mdis=EdiMaxD, vcheck=vcheck, device=device) if has_eedi3cl else dict(alpha=alpha, beta=beta, gamma=gamma, nrad=nrad, mdis=EdiMaxD, vcheck=vcheck)\n"
    content = content.replace(old_qtgmc_args, new_qtgmc_args)
    patched_eedi3cl = True

if patched_eedi3cl:
    patches.append('EEDI3CL fallback')

if patches:
    with open(havsfunc_path, 'w') as f:
        f.write(content)
    print(f"  Patched: {', '.join(patches)}")
else:
    print("  Already patched")
EOF
fi

# ============================================================================
# Repoint plugin support-lib references at the bundled copies in lib/
# ============================================================================
# Source-built plugins (mvtools, bm3d, dctfilter, nnedi3cl, ...) link Homebrew's
# fftw/boost by absolute path (e.g. /opt/homebrew/opt/fftw/lib/libfftw3f.3.dylib).
# Those paths don't exist on users' machines, so the plugin would fail to load.
# The libs are already bundled in $LIB_DIR; rewrite every such reference at the
# bundled copy. Also normalize each plugin's own install id to @loader_path so
# the bundle is fully relocatable.
echo ""
echo "=== Repointing plugin support-lib references to bundled lib/ ==="
SUPPORT_LIBS=(libfftw3f.3.dylib libfftw3f_threads.3.dylib libboost_filesystem.dylib libboost_atomic.dylib liblzma.5.dylib libdvdread.dylib)
for plugin in "$PLUGINS_DIR"/*.dylib; do
    [ -f "$plugin" ] || continue
    plugin_base=$(basename "$plugin")
    changed=false
    # Normalize the plugin's own install id.
    install_name_tool -id "@loader_path/$plugin_base" "$plugin" 2>/dev/null && changed=true
    # Repoint any dependency that matches a bundled support lib by basename.
    while IFS= read -r ref; do
        ref_base=$(basename "$ref")
        case "$ref_base" in "$plugin_base") continue ;; esac
        for sl in "${SUPPORT_LIBS[@]}"; do
            if [ "$ref_base" = "$sl" ] && [ -f "$LIB_DIR/$sl" ] && [[ "$ref" != @loader_path/* ]]; then
                install_name_tool -change "$ref" "@loader_path/../../lib/$sl" "$plugin" 2>/dev/null && changed=true
            fi
        done
    done < <(otool -L "$plugin" | tail -n +2 | awk '{print $1}')
    if [ "$changed" = true ]; then
        codesign -s - -f "$plugin" 2>/dev/null || true
        echo "  Repointed $plugin_base"
    fi
done

# The support libs in lib/ also link *each other* (e.g. libfftw3f_threads ->
# libfftw3f, libboost_filesystem -> libboost_atomic). Homebrew copies record
# those by absolute path -- and crucially by the *Cellar* path
# (/usr/local/Cellar/fftw/3.3.11/lib/libfftw3f.3.dylib), not the opt symlink, so
# a hardcoded `-change $BREW_PREFIX/opt/...` silently no-ops. Repoint sibling
# references by basename (path-agnostic) to @loader_path so the bundle resolves
# without Homebrew. This is the transitive half of issue #28: the FFT3DFilter
# plugin pointed at the bundled libfftw3f_threads, but that lib still pointed at
# Homebrew's libfftw3f.
for lib in "$LIB_DIR"/*.dylib; do
    [ -f "$lib" ] || continue
    lib_base=$(basename "$lib")
    changed=false
    install_name_tool -id "@loader_path/$lib_base" "$lib" 2>/dev/null && changed=true
    while IFS= read -r ref; do
        ref_base=$(basename "$ref")
        case "$ref_base" in "$lib_base") continue ;; esac
        for sl in "${SUPPORT_LIBS[@]}"; do
            # sibling lib in the same dir -> @loader_path/<name>
            if [ "$ref_base" = "$sl" ] && [ -f "$LIB_DIR/$sl" ] && [[ "$ref" != @loader_path/* ]]; then
                install_name_tool -change "$ref" "@loader_path/$sl" "$lib" 2>/dev/null && changed=true
            fi
        done
    done < <(otool -L "$lib" | tail -n +2 | awk '{print $1}')
    if [ "$changed" = true ]; then
        codesign -s - -f "$lib" 2>/dev/null || true
        echo "  Repointed lib/$lib_base"
    fi
done

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
echo "Plugin + support-lib external dylib references (must resolve on users' machines):"
UNBUNDLED_REFS=0
# Check both the plugins AND the support libs they depend on. Issue #28 recurred
# because the guard only inspected plugins: libfft3dfilter pointed correctly at
# the bundled libfftw3f_threads, but *that* lib still pointed at Homebrew's
# libfftw3f one level deeper, so the broken bundle shipped. Scanning lib/ too
# catches the transitive reference.
for dylib in "$PLUGINS_DIR"/*.dylib "$LIB_DIR"/*.dylib; do
    [ -f "$dylib" ] || continue
    dylib_base=$(basename "$dylib")
    while IFS= read -r ref; do
        ref_base=$(basename "$ref")
        case "$ref_base" in "$dylib_base") continue ;; esac
        # libdvdcss is the one *intentional* external reference: it is
        # deliberately NOT bundled (legal -- the user installs it themselves,
        # e.g. via Homebrew), and libdvdread weak-links it for optional CSS
        # decryption. Skip it so the guard stays strict for the issue #28 class
        # without flagging this by-design dependency.
        case "$ref_base" in libdvdcss*) continue ;; esac
        # A bundled support lib MUST be referenced via @loader_path (i.e. it was
        # repointed at deps/macos-*/lib by the repoint passes above). If it's
        # still @rpath or an absolute Homebrew path it won't resolve on a user
        # machine without Homebrew -- this is exactly the FFT3DFilter ->
        # libfftw3f_threads -> libfftw3f.3.dylib chain from issue #28, which
        # @rpath / absolute Cellar refs would otherwise slip past.
        for sl in "${SUPPORT_LIBS[@]}"; do
            if [ "$ref_base" = "$sl" ] && [[ "$ref" != @loader_path/* ]]; then
                echo "  ✗ $dylib_base: bundled support lib not repointed to @loader_path: $ref"
                UNBUNDLED_REFS=1
            fi
        done
        # Any other absolute, non-system dependency is also unbundled.
        case "$ref" in
            /usr/lib/*|/System/*|@loader_path/*|@rpath/*|@executable_path/*) ;;
            /*)
                echo "  ✗ $dylib_base references unbundled lib: $ref"
                UNBUNDLED_REFS=1
                ;;
        esac
    done < <(otool -L "$dylib" 2>/dev/null | tail -n +2 | awk '{print $1}')
done
if [ "$UNBUNDLED_REFS" = 0 ]; then
    echo "  ✓ all plugins reference only bundled (@loader_path) or system libraries"
else
    echo ""
    echo "ERROR: plugin(s) above reference libraries that won't exist on users'"
    echo "machines. Repoint them to @loader_path/../../lib (see the 'Repointing"
    echo "plugin support-lib references' pass) or bundle the lib into deps/macos-*/lib."
    echo "Failing the build to prevent shipping a broken bundle (see issue #28)."
    exit 1
fi

# ----------------------------------------------------------------------------
# Minimum-OS (minos) verification — x64 only (issue #39)
# ----------------------------------------------------------------------------
# Only the Intel bundle commits to back-deploying (to Monterey); the arm64 bundle
# is built on/for current macOS, so skip the check there to avoid spurious noise.
if [ "$ARCH" = "x86_64" ]; then
echo ""
echo "Minimum-OS (minos) of every bundled Mach-O (target $MACOS_MIN_VERSION, issue #39):"
# Print the macOS deployment target baked into a Mach-O, reading whichever load
# command it carries: LC_BUILD_VERSION (newer toolchains, "minos X.Y") or
# LC_VERSION_MIN_MACOSX (older, "version X.Y"). Empty for non-Mach-O files.
macho_minos() {
    otool -l "$1" 2>/dev/null | awk '
        /LC_BUILD_VERSION/      { inbuild=1; next }
        inbuild && /minos/      { print $2; exit }
        /LC_VERSION_MIN_MACOSX/ { inmin=1; next }
        inmin && /version/      { print $2; exit }
    '
}
# true if version $1 is strictly newer than $2 (e.g. 15.0 > 11.0)
version_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

TOO_NEW=0
while IFS= read -r macho; do
    [ -f "$macho" ] || continue
    file "$macho" 2>/dev/null | grep -q 'Mach-O' || continue
    minos=$(macho_minos "$macho")
    [ -n "$minos" ] || continue
    rel=${macho#"$DEPS_DIR"/}
    if version_gt "$minos" "$MACOS_MIN_VERSION"; then
        echo "  ✗ $rel: minos $minos > target $MACOS_MIN_VERSION"
        TOO_NEW=$((TOO_NEW + 1))
    fi
done < <(find "$DEPS_DIR" \( -name '*.dylib' -o -name '*.so' -o -name 'vspipe-bin' -o -name 'ffmpeg' -o -name 'ffprobe' \) -type f)

if [ "$TOO_NEW" = 0 ]; then
    echo "  ✓ every bundled binary targets macOS $MACOS_MIN_VERSION or older"
else
    echo ""
    echo "WARNING: $TOO_NEW binary(ies) above were built for a newer macOS than the"
    echo "target ($MACOS_MIN_VERSION) and will fail to load on older systems with a"
    echo "'dyld: Symbol not found' error (issue #39)."
    echo ""
    echo "The MACOSX_DEPLOYMENT_TARGET export fixes everything built from source here."
    echo "Anything still flagged is a *prebuilt* artifact this script only copies, so"
    echo "it needs its own fix:"
    echo "  - Homebrew bottles (zimg/fftw/boost/libdvdread/xz): the macos-15 runner"
    echo "    installs Sequoia bottles. Build these from source with the target set,"
    echo "    or fetch older-OS bottles."
    echo "  - ffmpeg (evermeet.cx / martin-riedl.de) and Python (python-build-standalone):"
    echo "    pick a download whose minos is <= $MACOS_MIN_VERSION."
    echo "  - Stefan-Olt / yuygfgg prebuilt plugins: rebuild from source if too new."
    echo ""
    # Opt-in hard fail once the prebuilt gaps above are closed, mirroring the
    # issue #28 guard. Default to warning so the first CI run still completes and
    # reports the full minos picture (including prebuilts we can't retarget by
    # env var); flip STRICT_MIN_OS=1 in the workflow once everything is <= target.
    if [ "${STRICT_MIN_OS:-0}" = "1" ]; then
        echo "STRICT_MIN_OS=1 set — failing the build."
        exit 1
    fi
fi
fi  # end x86_64-only minos verification

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
