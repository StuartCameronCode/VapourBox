#!/bin/bash
# Download and build dependencies for VapourBox on Linux (x86_64/aarch64)
# Builds VapourSynth plugins from source for native architecture support
# Creates a fully self-contained app with no system runtime dependencies
#
# Prerequisites:
#   sudo apt install -y meson ninja-build cmake nasm patchelf autoconf automake \
#     libtool pkg-config gcc g++ git python3 cython3 \
#     libfftw3-dev libboost-filesystem-dev libboost-atomic-dev \
#     ocl-icd-opencl-dev libdvdread-dev
#
# Usage: ./Scripts/download-deps-linux.sh [--force]

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
if [ "$ARCH" = "x86_64" ]; then
    PLATFORM_DIR="linux-x64"
elif [ "$ARCH" = "aarch64" ]; then
    PLATFORM_DIR="linux-arm64"
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
BUILD_PREFIX="$BUILD_DIR/install"
NPROC=$(nproc)

# Python version to embed
PYTHON_VERSION="3.12.8"
PYTHON_MAJOR_MINOR="3.12"

echo "=== VapourBox Linux Dependencies Builder ==="
echo "Architecture: $ARCH"
echo "Platform: $PLATFORM_DIR"
echo "Deps directory: $DEPS_DIR"
echo "Build directory: $BUILD_DIR"
echo "Force rebuild: $FORCE"
echo "Parallel jobs: $NPROC"
echo ""

# ============================================================================
# Check build prerequisites
# ============================================================================
echo "=== Checking build prerequisites ==="

MISSING_DEPS=()
for cmd in meson ninja cmake nasm patchelf pkg-config gcc g++ git autoconf automake libtoolize python3; do
    if ! command -v "$cmd" &>/dev/null; then
        MISSING_DEPS+=("$cmd")
    fi
done

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    echo "ERROR: Missing build tools: ${MISSING_DEPS[*]}"
    echo ""
    echo "Install with:"
    echo "  sudo apt install -y meson ninja-build cmake nasm patchelf autoconf automake \\"
    echo "    libtool pkg-config gcc g++ git python3 cython3"
    exit 1
fi

echo "  All build tools found"

# Create directories
mkdir -p "$DEPS_DIR"/{vapoursynth,ffmpeg,python,python-packages,lib,resources/NNEDI3CL}
mkdir -p "$PLUGINS_DIR"
mkdir -p "$BUILD_DIR"
mkdir -p "$BUILD_PREFIX"/{lib,include,lib/pkgconfig}

# ============================================================================
# Download and embed Python
# ============================================================================
echo ""
echo "=== Downloading embedded Python $PYTHON_VERSION ==="

if [ "$FORCE" = true ] || [ ! -f "$PYTHON_DIR/bin/python${PYTHON_MAJOR_MINOR}" ]; then
    if [ "$ARCH" = "x86_64" ]; then
        PYTHON_STANDALONE_URL="https://github.com/indygreg/python-build-standalone/releases/download/20241206/cpython-${PYTHON_VERSION}+20241206-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz"
    else
        PYTHON_STANDALONE_URL="https://github.com/indygreg/python-build-standalone/releases/download/20241206/cpython-${PYTHON_VERSION}+20241206-aarch64-unknown-linux-gnu-install_only_stripped.tar.gz"
    fi

    echo "  Downloading python-build-standalone..."
    curl -L -o "$BUILD_DIR/python-standalone.tar.gz" "$PYTHON_STANDALONE_URL"

    echo "  Extracting Python..."
    rm -rf "$PYTHON_DIR"/*
    mkdir -p "$PYTHON_DIR"
    tar -xzf "$BUILD_DIR/python-standalone.tar.gz" -C "$PYTHON_DIR" --strip-components=1

    PYTHON_BIN="$PYTHON_DIR/bin/python${PYTHON_MAJOR_MINOR}"
    echo "  Python installed to: $PYTHON_DIR"
    "$PYTHON_BIN" --version
else
    echo "  Python already installed, skipping"
fi

# Set Python paths for building
PYTHON_BIN="$PYTHON_DIR/bin/python${PYTHON_MAJOR_MINOR}"
PYTHON_LIB="$PYTHON_DIR/lib/libpython${PYTHON_MAJOR_MINOR}.so"
PYTHON_INCLUDE="$PYTHON_DIR/include/python${PYTHON_MAJOR_MINOR}"

# ============================================================================
# Build zimg from source (VapourSynth dependency)
# ============================================================================
echo ""
echo "=== Building zimg ==="

if [ "$FORCE" = true ] || [ ! -f "$BUILD_PREFIX/lib/libzimg.so" ]; then
    cd "$BUILD_DIR"
    rm -rf zimg
    git clone --depth 1 --recursive https://github.com/sekrit-twc/zimg.git zimg
    cd zimg
    ./autogen.sh
    ./configure --prefix="$BUILD_PREFIX"
    make -j"$NPROC"
    make install

    # Copy to deps
    cp "$BUILD_PREFIX/lib/libzimg.so"* "$DEPS_DIR/vapoursynth/"
    echo "  Built zimg"
else
    echo "  zimg already built, skipping"
fi

# ============================================================================
# Build VapourSynth from source with embedded Python
# ============================================================================
echo ""
echo "=== Building VapourSynth from source ==="

VS_TAG="R78"
VS_BUILD_DIR="$BUILD_DIR/vapoursynth"
VS_INSTALL_DIR="$BUILD_DIR/vapoursynth-install"

if [ "$FORCE" = true ] || [ ! -f "$DEPS_DIR/vapoursynth/libvapoursynth.so" ]; then
    echo "  Cloning VapourSynth $VS_TAG..."
    rm -rf "$VS_BUILD_DIR"
    git clone --depth 1 --branch "$VS_TAG" https://github.com/vapoursynth/vapoursynth.git "$VS_BUILD_DIR" 2>/dev/null || \
    git clone --depth 1 https://github.com/vapoursynth/vapoursynth.git "$VS_BUILD_DIR"

    cd "$VS_BUILD_DIR"

    # zimg API guard (backport of upstream 37eed3dd). R78 reads zimg's
    # chromatic_adaptation field unconditionally, but it only exists in a zimg
    # newer than the current release, so R78 builds against no released zimg.
    # See the patch header. Hard-fail rather than die in the compiler.
    git apply "$SCRIPT_DIR/patches/vapoursynth-r78-zimg-api-guard.patch" || {
        echo "  ERROR: patches/vapoursynth-r78-zimg-api-guard.patch did not apply." >&2
        echo "  If VapourSynth has moved past R78 the fix is already upstream — drop it." >&2
        exit 1
    }
    echo "  Applied the zimg chromatic_adaptation API guard"

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

    # Copy zimg pkg-config from the build (has correct version)
    if [ -f "$BUILD_PREFIX/lib/pkgconfig/zimg.pc" ]; then
        cp "$BUILD_PREFIX/lib/pkgconfig/zimg.pc" "$BUILD_DIR/pkgconfig/"
    fi

    echo "  Configuring VapourSynth..."
    PATH="$PYTHON_DIR/bin:$PATH" \
    PKG_CONFIG_PATH="$BUILD_DIR/pkgconfig:$BUILD_PREFIX/lib/pkgconfig" \
    LD_LIBRARY_PATH="$PYTHON_DIR/lib:$BUILD_PREFIX/lib:${LD_LIBRARY_PATH:-}" \
    meson setup build \
        --prefix="$VS_INSTALL_DIR" \
        --buildtype=release \
        -Dlibdir=lib \
        -Dplugindir="" \
        -Dpython3_bin="$PYTHON_BIN"

    echo "  Building VapourSynth..."
    PATH="$PYTHON_DIR/bin:$PATH" \
    LD_LIBRARY_PATH="$PYTHON_DIR/lib:$BUILD_PREFIX/lib:${LD_LIBRARY_PATH:-}" \
    ninja -C build
    PATH="$PYTHON_DIR/bin:$PATH" \
    LD_LIBRARY_PATH="$PYTHON_DIR/lib:$BUILD_PREFIX/lib:${LD_LIBRARY_PATH:-}" \
    ninja -C build install

    echo "  Copying VapourSynth files..."
    # Copy vspipe
    # Copy from the build directory, not the install prefix: R74 turned
    # VapourSynth into a Python package, so `ninja install` puts everything
    # under <prefix>/<python-site-packages>/vapoursynth/ instead of bin/ and
    # lib/. The build directory is flat and Python-independent.
    VS_BUILT="$VS_BUILD_DIR/build"

    cp "$VS_BUILT/vspipe" "$DEPS_DIR/vapoursynth/vspipe-bin"
    chmod +x "$DEPS_DIR/vapoursynth/vspipe-bin"

    # Copy libraries
    cp "$VS_BUILT/libvapoursynth.so"* "$DEPS_DIR/vapoursynth/"
    # vapoursynth-script was renamed vsscript in R78.
    cp "$VS_BUILT/libvsscript.so"* "$DEPS_DIR/vapoursynth/"
    # R78 split every core filter (std, resize, ...) out of libvapoursynth into
    # this module; without it the core namespaces are absent and every job fails.
    cp "$VS_BUILT/libvapoursynthfilters.so"* "$DEPS_DIR/vapoursynth/"

    # Copy Python module
    cp "$VS_BUILT/vapoursynth.abi3.so" "$PYTHON_PACKAGES_DIR/"

    # Fix RPATHs
    echo "  Fixing RPATHs..."
    patchelf --set-rpath '$ORIGIN' "$DEPS_DIR/vapoursynth/vspipe-bin"
    for lib in "$DEPS_DIR/vapoursynth"/libvapoursynth*.so*; do
        [ -f "$lib" ] && [ ! -L "$lib" ] && patchelf --set-rpath '$ORIGIN:$ORIGIN/../python/lib' "$lib" 2>/dev/null || true
    done
    for so_file in "$PYTHON_PACKAGES_DIR"/vapoursynth*.so; do
        [ -f "$so_file" ] && patchelf --set-rpath '$ORIGIN/../vapoursynth:$ORIGIN/../python/lib' "$so_file" 2>/dev/null || true
    done

    # Create wrapper script (same concept as macOS)
    cat > "$DEPS_DIR/vapoursynth/vspipe" << 'WRAPPER_EOF'
#!/bin/bash
# VapourSynth vspipe wrapper - fully self-contained
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPS_ROOT="$(dirname "$SCRIPT_DIR")"

export PATH="$DEPS_ROOT/python/bin:$PATH"
export PYTHONHOME="$DEPS_ROOT/python"
export VAPOURSYNTH_PLUGIN_PATH="$SCRIPT_DIR/plugins"
export PYTHONPATH="$DEPS_ROOT/python-packages:${PYTHONPATH:-}"
export LD_LIBRARY_PATH="$SCRIPT_DIR:$DEPS_ROOT/python/lib:$DEPS_ROOT/lib:${LD_LIBRARY_PATH:-}"

# R74 removed the config-file mechanism entirely (UserPluginDir /
# AutoloadUserPluginDir / VAPOURSYNTH_CONF_PATH no longer exist). Plugins come
# from <libdir>/plugins plus this variable.
export VAPOURSYNTH_EXTRA_PLUGIN_PATH="$SCRIPT_DIR/plugins"

exec "$SCRIPT_DIR/vspipe-bin" "$@"
WRAPPER_EOF
    chmod +x "$DEPS_DIR/vapoursynth/vspipe"

    # Copy VS headers to deps for plugin builds (persists across runs)
    mkdir -p "$DEPS_DIR/vapoursynth/include"
    cp "$VS_INSTALL_DIR/include/vapoursynth/"*.h "$DEPS_DIR/vapoursynth/include/"

    cd "$BUILD_DIR"
    echo "  Built VapourSynth from source with embedded Python"
else
    echo "  VapourSynth already built, skipping"
fi

# Set VS include dir for plugin builds (persisted in deps, survives temp dir cleanup)
VS_INCLUDE_DIR="$DEPS_DIR/vapoursynth/include"

# Create vapoursynth/ subdirectory symlinks for plugins that use #include <vapoursynth/VapourSynth.h>
mkdir -p "$VS_INCLUDE_DIR/vapoursynth"
for h in "$VS_INCLUDE_DIR"/*.h; do
    [ -f "$h" ] && ln -sf "../$(basename "$h")" "$VS_INCLUDE_DIR/vapoursynth/$(basename "$h")" 2>/dev/null || true
done

# Make VapourSynth pkg-config available for plugin builds
# Use the installed pkg-config files but patch the paths
mkdir -p "$BUILD_DIR/pkgconfig"
# Create pkg-config pointing to persisted headers and deps libs
cat > "$BUILD_DIR/pkgconfig/vapoursynth.pc" << EOF
prefix=$DEPS_DIR/vapoursynth
libdir=\${prefix}
includedir=\${prefix}/include

Name: VapourSynth
Description: VapourSynth
Version: 73
Libs: -L\${libdir} -lvapoursynth
Cflags: -I\${includedir}
EOF
cp "$BUILD_DIR/pkgconfig/vapoursynth.pc" "$BUILD_DIR/pkgconfig/vapoursynth-script.pc"

# ============================================================================
# Download FFmpeg (static build)
# ============================================================================
echo ""
echo "=== Downloading FFmpeg ==="

if [ "$FORCE" = true ] || [ ! -f "$DEPS_DIR/ffmpeg/ffmpeg" ]; then
    # BtbN static GPL builds include hardware encoders (x64: QSV/NVENC/AMF/VAAPI;
    # arm64: NVENC/AMF/V4L2M2M) yet run software-only on machines without a GPU or
    # driver — the vendor runtimes (libvpl/libnvidia-encode/libva) are dlopen'd
    # lazily, so libx264/libx265 always work and absent hw encoders fail
    # gracefully at init. (The previous John Van Sickle build had no hw accel.)
    BTBN_BASE="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest"
    if [ "$ARCH" = "x86_64" ]; then
        FFMPEG_URL="$BTBN_BASE/ffmpeg-n7.1-latest-linux64-gpl-7.1.tar.xz"
    else
        FFMPEG_URL="$BTBN_BASE/ffmpeg-n7.1-latest-linuxarm64-gpl-7.1.tar.xz"
    fi

    echo "  Downloading static FFmpeg (BtbN, hardware-enabled)..."
    curl -L -o "$BUILD_DIR/ffmpeg.tar.xz" "$FFMPEG_URL"

    echo "  Extracting..."
    tar -xJf "$BUILD_DIR/ffmpeg.tar.xz" -C "$BUILD_DIR"
    # BtbN tarballs lay the binaries out under <dirname>/bin/
    FFMPEG_BIN=$(find "$BUILD_DIR" -maxdepth 3 -path "*/bin/ffmpeg" -type f | head -1)
    if [ -z "$FFMPEG_BIN" ]; then
        echo "  ERROR: Could not find extracted FFmpeg binary"
        exit 1
    fi
    FFMPEG_DIR=$(dirname "$FFMPEG_BIN")

    cp "$FFMPEG_DIR/ffmpeg" "$DEPS_DIR/ffmpeg/"
    cp "$FFMPEG_DIR/ffprobe" "$DEPS_DIR/ffmpeg/"
    chmod +x "$DEPS_DIR/ffmpeg/ffmpeg" "$DEPS_DIR/ffmpeg/ffprobe"
    echo "  Downloaded FFmpeg"
else
    echo "  FFmpeg already exists, skipping"
fi

# ============================================================================
# Copy FFTW3 (float, threads)
# ============================================================================
echo ""
echo "=== Copying FFTW3 ==="

LIB_DIR="$DEPS_DIR/lib"
mkdir -p "$LIB_DIR"

# Copy system FFTW if available
FFTW_FOUND=false
for libdir in /usr/lib/$ARCH-linux-gnu /usr/lib64 /usr/lib; do
    if [ -f "$libdir/libfftw3f.so" ] || [ -f "$libdir/libfftw3f.so.3" ]; then
        cp -L "$libdir/libfftw3f.so"* "$LIB_DIR/" 2>/dev/null || true
        cp -L "$libdir/libfftw3f_threads.so"* "$LIB_DIR/" 2>/dev/null || true
        FFTW_FOUND=true
        echo "  Copied FFTW3 from $libdir"
        break
    fi
done

if [ "$FFTW_FOUND" = false ]; then
    echo "  WARNING: FFTW3 not found. Some plugins may not work."
    echo "  Install with: sudo apt install libfftw3-dev"
fi

# Fix FFTW RPATHs
for lib in "$LIB_DIR"/libfftw3f*.so*; do
    [ -f "$lib" ] && [ ! -L "$lib" ] && patchelf --set-rpath '$ORIGIN' "$lib" 2>/dev/null || true
done

# ============================================================================
# Copy Boost libraries (filesystem, atomic — needed by some plugins)
# ============================================================================
echo ""
echo "=== Copying Boost libraries ==="

BOOST_FOUND=false
for libdir in /usr/lib/$ARCH-linux-gnu /usr/lib64 /usr/lib; do
    if [ -f "$libdir/libboost_filesystem.so" ] || ls "$libdir"/libboost_filesystem.so.* &>/dev/null; then
        cp -L "$libdir/libboost_filesystem.so"* "$LIB_DIR/" 2>/dev/null || true
        cp -L "$libdir/libboost_atomic.so"* "$LIB_DIR/" 2>/dev/null || true
        BOOST_FOUND=true
        echo "  Copied Boost from $libdir"
        break
    fi
done

if [ "$BOOST_FOUND" = false ]; then
    echo "  WARNING: Boost not found (optional — needed by NNEDI3CL)"
fi

# Fix Boost RPATHs
for lib in "$LIB_DIR"/libboost_*.so*; do
    [ -f "$lib" ] && [ ! -L "$lib" ] && patchelf --set-rpath '$ORIGIN' "$lib" 2>/dev/null || true
done

# ============================================================================
# Copy OpenCL ICD loader (thin library, loads vendor ICDs)
# ============================================================================
echo ""
echo "=== Copying OpenCL ICD loader ==="

OPENCL_FOUND=false
for libdir in /usr/lib/$ARCH-linux-gnu /usr/lib64 /usr/lib; do
    if [ -f "$libdir/libOpenCL.so.1" ] || [ -f "$libdir/libOpenCL.so" ]; then
        cp -L "$libdir/libOpenCL.so"* "$LIB_DIR/" 2>/dev/null || true
        OPENCL_FOUND=true
        echo "  Copied OpenCL ICD loader from $libdir"
        break
    fi
done

if [ "$OPENCL_FOUND" = false ]; then
    echo "  WARNING: OpenCL ICD loader not found (optional — GPU plugins degrade gracefully)"
    echo "  Install with: sudo apt install ocl-icd-libopencl1"
fi

# ============================================================================
# Build plugins from source
# ============================================================================
cd "$BUILD_DIR"

BUILT_PLUGINS=()
FAILED_PLUGINS=()

# Patch meson.build files that use python3 to detect VS include path.
# Some plugins run `python3 -c 'import vapoursynth; print(vs.get_include())'`
# which fails with our bundled Python. Replace with hardcoded include path.
patch_meson_vs_include() {
    [ ! -f meson.build ] && return
    python3 -c "
import re
with open('meson.build', 'r') as f:
    content = f.read()
content = re.sub(
    r'incdir\s*=\s*include_directories\s*\(\s*run_command\s*\(.*?\)\.stdout\(\)\.strip\(\)\s*,?\s*\)',
    \"incdir = include_directories('$VS_INCLUDE_DIR')\",
    content,
    flags=re.DOTALL
)
with open('meson.build', 'w') as f:
    f.write(content)
" 2>/dev/null || true
}

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

    # Patch meson.build if it uses python3 to detect VS include path
    patch_meson_vs_include

    if eval "$build_cmd"; then
        local lib_path=$(find . -name "*.so" -type f 2>/dev/null | head -1)
        if [ -n "$lib_path" ]; then
            cp "$lib_path" "$PLUGINS_DIR/$output_lib"
            # Fix RPATH for plugin
            patchelf --set-rpath '$ORIGIN:$ORIGIN/../../lib' "$PLUGINS_DIR/$output_lib" 2>/dev/null || true
            echo "  Built $name -> $output_lib"
            BUILT_PLUGINS+=("$name")
        else
            echo "  Warning: No .so found for $name"
            FAILED_PLUGINS+=("$name")
        fi
    else
        echo "  Failed to build $name"
        FAILED_PLUGINS+=("$name")
    fi

    cd "$BUILD_DIR"
}

# Common build environment for meson plugins
PLUGIN_PKG_CONFIG="$BUILD_DIR/pkgconfig:$BUILD_PREFIX/lib/pkgconfig"
PLUGIN_BUILD_ENV="PKG_CONFIG_PATH=$PLUGIN_PKG_CONFIG"

# MVTools (essential for QTGMC motion compensation)
build_plugin "mvtools" \
    "https://github.com/dubhater/vapoursynth-mvtools.git" \
    "libmvtools.so" \
    "$PLUGIN_BUILD_ENV meson setup build --buildtype=release && ninja -C build"

# ZNEDI3 (neural network interpolation - primary for QTGMC)
echo ""
echo "=== Building ZNEDI3 ==="
if [ "$FORCE" = true ] || [ ! -f "$PLUGINS_DIR/libznedi3.so" ]; then
    rm -rf znedi3
    git clone --depth 1 --recursive https://github.com/sekrit-twc/znedi3.git znedi3
    cd znedi3
    ZNEDI3_OK=false
    if [ "$ARCH" = "aarch64" ]; then
        CXXFLAGS="-I$VS_INCLUDE_DIR -I$VS_INCLUDE_DIR" \
        make X86=0 X86_AVX512=0 -j"$NPROC" 2>/dev/null && ZNEDI3_OK=true || \
        { CXXFLAGS="-I$VS_INCLUDE_DIR -I$VS_INCLUDE_DIR" \
        make -j"$NPROC" && ZNEDI3_OK=true; } || true
    else
        CXXFLAGS="-I$VS_INCLUDE_DIR -I$VS_INCLUDE_DIR" \
        make -j"$NPROC" && ZNEDI3_OK=true || true
    fi
    if $ZNEDI3_OK; then
        if [ -f "vsznedi3.so" ]; then
            cp vsznedi3.so "$PLUGINS_DIR/libznedi3.so"
        else
            find . -name "*.so" | head -1 | xargs -I {} cp {} "$PLUGINS_DIR/libznedi3.so" 2>/dev/null || true
        fi
        [ -f "nnedi3_weights.bin" ] && cp nnedi3_weights.bin "$PLUGINS_DIR/"
        patchelf --set-rpath '$ORIGIN:$ORIGIN/../../lib' "$PLUGINS_DIR/libznedi3.so" 2>/dev/null || true
        BUILT_PLUGINS+=("znedi3")
        echo "  Built ZNEDI3"
    else
        echo "  Failed to build ZNEDI3"
        FAILED_PLUGINS+=("znedi3")
    fi
    cd "$BUILD_DIR"
else
    echo "  ZNEDI3 already exists, skipping"
fi

# NNEDI3 (CPU version)
echo ""
echo "=== Building NNEDI3 ==="
if [ "$FORCE" = true ] || [ ! -f "$PLUGINS_DIR/libnnedi3.so" ]; then
    rm -rf nnedi3
    git clone --depth 1 https://github.com/dubhater/vapoursynth-nnedi3.git nnedi3
    cd nnedi3
    if ./autogen.sh && \
       PKG_CONFIG_PATH="$PLUGIN_PKG_CONFIG" \
       CFLAGS="-I$VS_INCLUDE_DIR" \
       CXXFLAGS="-I$VS_INCLUDE_DIR" \
       ./configure && \
       make -j"$NPROC"; then
        find . -name "libnnedi3.so" | head -1 | xargs -I {} cp {} "$PLUGINS_DIR/libnnedi3.so" 2>/dev/null || \
            find . -name "*.so" | head -1 | xargs -I {} cp {} "$PLUGINS_DIR/libnnedi3.so" 2>/dev/null
        patchelf --set-rpath '$ORIGIN:$ORIGIN/../../lib' "$PLUGINS_DIR/libnnedi3.so" 2>/dev/null || true
        BUILT_PLUGINS+=("nnedi3")
        echo "  Built NNEDI3"
    else
        echo "  Failed to build NNEDI3 (may not support this architecture)"
        FAILED_PLUGINS+=("nnedi3")
    fi
    cd "$BUILD_DIR"
else
    echo "  NNEDI3 already exists, skipping"
fi

# NNEDI3CL (OpenCL version)
build_plugin "nnedi3cl" \
    "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-NNEDI3CL.git" \
    "libnnedi3cl.so" \
    "$PLUGIN_BUILD_ENV meson setup build --buildtype=release && ninja -C build"

# EEDI3m (edge-directed interpolation)
# Patch: add missing <cstddef> include for std::max_align_t (GCC 13+)
build_plugin "eedi3m" \
    "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-EEDI3.git" \
    "libeedi3m.so" \
    "sed -i '1i #include <cstddef>' EEDI3/EEDI3.cpp && $PLUGIN_BUILD_ENV meson setup build --buildtype=release && ninja -C build"

# fmtconv (format conversion)
# Upstream moved to GitLab in Aug 2023; the GitHub repo is an abandoned mirror
# whose final commit is literally "Repository moved to Gitlab", so cloning its
# master pinned us to a stale post-r30 snapshot. Use GitLab and pin the tag so
# the build is reproducible and every platform ships the same fmtconv version
# (r31 also fixes interlaced PAL-DV chroma placement — U/V vertical positions
# were swapped and vertical subsampling > 2 was unhandled).
# NOTE: r31 does NOT fix the aarch64 integer-scaler bug (vertical resampling of
# sub-16-bit sources returns black). We fix that ourselves with
# patches/fmtconv-r31-arm-int-scaler.patch, applied right after the clone below.
FMTCONV_TAG="r31"
echo ""
echo "=== Building fmtconv ($FMTCONV_TAG) ==="
if [ "$FORCE" = true ] || [ ! -f "$PLUGINS_DIR/libfmtconv.so" ]; then
    rm -rf fmtconv
    git clone --depth 1 --branch "$FMTCONV_TAG" https://gitlab.com/EleonoreMizo/fmtconv.git fmtconv
    # Fix the non-x86 integer vertical scaler, which returns a black plane for
    # any source below 16-bit — that is what broke havsfunc's Bob(), and with it
    # QTGMC's Placebo/Very Slow noise pass and the Draft preset. The patch header
    # has the full analysis. Hard-fail rather than silently shipping the bug back.
    (cd fmtconv && git apply "$SCRIPT_DIR/patches/fmtconv-r31-arm-int-scaler.patch") || {
        echo "  ERROR: patches/fmtconv-r31-arm-int-scaler.patch did not apply." >&2
        echo "  fmtconv $FMTCONV_TAG may have changed upstream — re-check the patch." >&2
        exit 1
    }
    echo "  Patched fmtconv integer scaler (non-x86 vertical resample)"
    cd fmtconv/build/unix
    if ./autogen.sh && \
       PKG_CONFIG_PATH="$PLUGIN_PKG_CONFIG" \
       CXXFLAGS="-I$VS_INCLUDE_DIR" \
       ./configure && \
       make -j"$NPROC"; then
        find ../.. -name "libfmtconv*.so" | head -1 | xargs -I {} cp {} "$PLUGINS_DIR/libfmtconv.so" 2>/dev/null || \
            cp .libs/libfmtconv.so "$PLUGINS_DIR/" 2>/dev/null
        patchelf --set-rpath '$ORIGIN:$ORIGIN/../../lib' "$PLUGINS_DIR/libfmtconv.so" 2>/dev/null || true
        BUILT_PLUGINS+=("fmtconv")
        echo "  Built fmtconv"
    else
        echo "  Failed to build fmtconv"
        FAILED_PLUGINS+=("fmtconv")
    fi
    cd "$BUILD_DIR"
else
    echo "  fmtconv already exists, skipping"
fi

# DFTTest (FFT-based denoising)
build_plugin "dfttest" \
    "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-DFTTest.git" \
    "libdfttest.so" \
    "$PLUGIN_BUILD_ENV meson setup build --buildtype=release && ninja -C build"

# TTempSmooth (core.ttmpsm.TTempSmooth - used by havsfunc MCTemporalDenoise)
build_plugin "ttempsmooth" \
    "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-TTempSmooth.git" \
    "libttempsmooth.so" \
    "$PLUGIN_BUILD_ENV meson setup build --buildtype=release && ninja -C build"

# FFT3DFilter
build_plugin "fft3dfilter" \
    "https://github.com/myrsloik/VapourSynth-FFT3DFilter.git" \
    "libfft3dfilter.so" \
    "$PLUGIN_BUILD_ENV meson setup build --buildtype=release && ninja -C build"

# MiscFilters
build_plugin "miscfilters" \
    "https://github.com/vapoursynth/vs-miscfilters-obsolete.git" \
    "libmiscfilters.so" \
    "$PLUGIN_BUILD_ENV meson setup build --buildtype=release && ninja -C build"

# RemoveGrain
build_plugin "removegrain" \
    "https://github.com/vapoursynth/vs-removegrain.git" \
    "libremovegrain.so" \
    "$PLUGIN_BUILD_ENV meson setup build --buildtype=release && ninja -C build"

# AddGrain
build_plugin "addgrain" \
    "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-AddGrain.git" \
    "libaddgrain.so" \
    "$PLUGIN_BUILD_ENV meson setup build --buildtype=release && ninja -C build"

# VIVTC (inverse telecine - VFM + VDecimate)
build_plugin "vivtc" \
    "https://github.com/vapoursynth/vivtc.git" \
    "libvivtc.so" \
    "$PLUGIN_BUILD_ENV meson setup build --buildtype=release && ninja -C build"

# neo-f3kdb (debanding)
echo ""
echo "=== Building neo-f3kdb ==="
if [ "$FORCE" = true ] || [ ! -f "$PLUGINS_DIR/libneo-f3kdb.so" ]; then
    rm -rf f3kdb
    git clone --depth 1 https://github.com/HomeOfAviSynthPlusEvolution/neo_f3kdb.git f3kdb
    cd f3kdb
    # Remove TBB dependency (not always available, optional for threading)
    sed -i 's/target_link_libraries.*tbb.*//' CMakeLists.txt 2>/dev/null || true
    if cmake -B build -S . -DCMAKE_BUILD_TYPE=Release && \
       cmake --build build --config Release -j"$NPROC"; then
        find build -name "*.so" | head -1 | xargs -I {} cp {} "$PLUGINS_DIR/libneo-f3kdb.so"
        patchelf --set-rpath '$ORIGIN:$ORIGIN/../../lib' "$PLUGINS_DIR/libneo-f3kdb.so" 2>/dev/null || true
        BUILT_PLUGINS+=("neo-f3kdb")
        echo "  Built neo-f3kdb"
    else
        echo "  Failed to build neo-f3kdb"
        FAILED_PLUGINS+=("neo-f3kdb")
    fi
    cd "$BUILD_DIR"
else
    echo "  neo-f3kdb already exists, skipping"
fi

# CAS (Contrast Adaptive Sharpening)
build_plugin "cas" \
    "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-CAS.git" \
    "libcas.so" \
    "$PLUGIN_BUILD_ENV meson setup build --buildtype=release && ninja -C build"

# DCTFilter
build_plugin "dctfilter" \
    "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-DCTFilter.git" \
    "libdctfilter.so" \
    "$PLUGIN_BUILD_ENV meson setup build --buildtype=release && ninja -C build"

# Deblock
build_plugin "deblock" \
    "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-Deblock.git" \
    "libdeblock.so" \
    "$PLUGIN_BUILD_ENV meson setup build --buildtype=release && ninja -C build"

# AWarpSharp2
build_plugin "awarpsharp2" \
    "https://github.com/dubhater/vapoursynth-awarpsharp2.git" \
    "libawarpsharp2.so" \
    "$PLUGIN_BUILD_ENV meson setup build --buildtype=release && ninja -C build"

# CTMF (Constant Time Median Filter)
build_plugin "ctmf" \
    "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-CTMF.git" \
    "libctmf.so" \
    "$PLUGIN_BUILD_ENV meson setup build --buildtype=release && ninja -C build"

# TCanny (edge detection)
build_plugin "tcanny" \
    "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-TCanny.git" \
    "libtcanny.so" \
    "$PLUGIN_BUILD_ENV meson setup build --buildtype=release && ninja -C build"

# BM3D
build_plugin "bm3d" \
    "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-BM3D.git" \
    "libbm3d.so" \
    "$PLUGIN_BUILD_ENV meson setup build --buildtype=release && ninja -C build"

# KNLMeansCL (OpenCL denoiser)
build_plugin "knlmeanscl" \
    "https://github.com/Khanattila/KNLMeansCL.git" \
    "libknlmeanscl.so" \
    "$PLUGIN_BUILD_ENV meson setup build --buildtype=release && ninja -C build"

# TemporalMedian (core.tmedian.TemporalMedian - used by the SpotLess filter)
build_plugin "tmedian" \
    "https://github.com/dubhater/vapoursynth-temporalmedian.git" \
    "libtmedian.so" \
    "$PLUGIN_BUILD_ENV meson setup build --buildtype=release && ninja -C build"

# zsmooth (core.zsmooth.CCD - chroma denoiser; also Cnr4 and a set of
# RemoveGrain/TemporalMedian-family filters).
#
# Taken pre-built rather than built from source: zsmooth is written in Zig, and
# adding a Zig toolchain to every deps build for one plugin is not worth it. The
# author publishes a binary for every platform/arch VapourBox targets.
#
# Keep ZSMOOTH_VERSION in step across download-deps-{macos,linux}.sh and
# download-deps-windows.ps1 — a version skew would make the same job produce
# different chroma per OS.
ZSMOOTH_VERSION="0.19.0"
case "$ARCH" in
    aarch64|arm64) ZSMOOTH_ASSET="zsmooth-aarch64-linux-gnu.zip" ;;
    *)             ZSMOOTH_ASSET="zsmooth-x86_64-linux-gnu.zip" ;;
esac
echo ""
echo "=== Downloading zsmooth ==="
if [ "$FORCE" = true ] || [ ! -f "$PLUGINS_DIR/libzsmooth.so" ]; then
    rm -rf "$BUILD_DIR/zsmooth"
    mkdir -p "$BUILD_DIR/zsmooth"
    if curl -sL -o "$BUILD_DIR/zsmooth/zsmooth.zip" \
        "https://github.com/adworacz/zsmooth/releases/download/${ZSMOOTH_VERSION}/${ZSMOOTH_ASSET}" \
        && unzip -q -o "$BUILD_DIR/zsmooth/zsmooth.zip" -d "$BUILD_DIR/zsmooth"; then
        so_path=$(find "$BUILD_DIR/zsmooth" -name "*.so" -type f 2>/dev/null | head -1)
        if [ -n "$so_path" ]; then
            cp "$so_path" "$PLUGINS_DIR/libzsmooth.so"
            patchelf --set-rpath '$ORIGIN:$ORIGIN/../../lib' "$PLUGINS_DIR/libzsmooth.so" 2>/dev/null || true
            echo "  Downloaded pre-built zsmooth -> libzsmooth.so"
            BUILT_PLUGINS+=("zsmooth")
        else
            echo "  Failed: no .so in the zsmooth archive"
            FAILED_PLUGINS+=("zsmooth")
        fi
    else
        echo "  Failed to download zsmooth"
        FAILED_PLUGINS+=("zsmooth")
    fi
    rm -rf "$BUILD_DIR/zsmooth"
else
    echo "  zsmooth already exists, skipping"
fi

# DeScratch (core.descratch.DeScratch - vertical scratch removal)
# Built from source: the repo carries the VapourSynth + AviSynthPlus headers as
# submodules, so a recursive clone is required (build_plugin can't fetch those).
echo ""
echo "=== Building DeScratch ==="
if [ "$FORCE" = true ] || [ ! -f "$PLUGINS_DIR/libdescratch.so" ]; then
    rm -rf descratch
    if git clone --depth 1 --recurse-submodules --shallow-submodules \
        https://github.com/vapoursynth/descratch.git descratch; then
        cd descratch
        if meson setup build --buildtype=release && ninja -C build; then
            lib_path=$(find build -name "*.so" -type f 2>/dev/null | head -1)
            if [ -n "$lib_path" ]; then
                cp "$lib_path" "$PLUGINS_DIR/libdescratch.so"
                patchelf --set-rpath '$ORIGIN:$ORIGIN/../../lib' "$PLUGINS_DIR/libdescratch.so" 2>/dev/null || true
                echo "  Built DeScratch -> libdescratch.so"
                BUILT_PLUGINS+=("descratch")
            else
                echo "  Warning: No .so found for DeScratch"
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
    HAVSFUNC_PATH="$HAVSFUNC" python3 << 'PYEOF'
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

# Patch 4: EEDI3CL fallback
patched_eedi3cl = False
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

# Patch 5: Bob() bit depth — fmtconv's generic (non-x86-SIMD) VERTICAL resampler
# returns black for any input below 16-bit. havsfunc's Bob() bobs fields with
# fmtc.resample(scalev=2, ...), so on aarch64 it destroys the image outright.
# That silently broke two QTGMC paths:
#   - Placebo / Very Slow are the only presets that default NoiseProcess=2, and
#     that noise pass calls Bob() to expand fields before extracting noise. The
#     near-black "denoised" clip made MakeDiff clip hard, so GrainRestore/
#     NoiseRestore merged in a large positive bias: ~+10/255 brighter output.
#   - Draft sets EdiMode='bob', which interpolates via Bob() — near-black output.
# Horizontal resampling and >=16-bit input are fine, which is why Slower and
# below (whose only fmtconv use is the same-size Sbb gauss blur) look correct.
# x86 is unaffected: its SSE2/AVX2 scalers override the broken generic path, so
# this only ever hit linux-arm64 and macos-arm64. Still broken in upstream r31.
# Promote to 16-bit before the resample — Bob()'s existing tail already dithers
# back to the source depth, and fmtconv keeps doing its own interlaced chroma
# placement (which zimg would not).
old_bob = "    clip = core.std.SeparateFields(clip, tff).fmtc.resample(scalev=2, kernel='bicubic', a1=b, a2=c, interlaced=1, interlacedd=0)\n"
if old_bob in content:
    content = content.replace(
        old_bob,
        "    _bob_fields = core.std.SeparateFields(clip, tff)\n"
        "    if bits < 16:\n"
        "        _bob_fields = core.fmtc.bitdepth(_bob_fields, bits=16)\n"
        "    clip = _bob_fields.fmtc.resample(scalev=2, kernel='bicubic', a1=b, a2=c, interlaced=1, interlacedd=0)\n"
    )
    patches.append('Bob 16-bit resample')

if patches:
    with open(havsfunc_path, 'w') as f:
        f.write(content)
    print(f"  Patched: {', '.join(patches)}")
else:
    print("  Already patched")
PYEOF
fi

# ============================================================================
# Copy libdvdread
# ============================================================================
echo ""
echo "=== Copying libdvdread ==="

DVDREAD_FOUND=false
for libdir in /usr/lib/$ARCH-linux-gnu /usr/lib64 /usr/lib /usr/local/lib; do
    if [ -f "$libdir/libdvdread.so" ] || ls "$libdir"/libdvdread.so.* &>/dev/null; then
        cp -L "$libdir/libdvdread.so"* "$LIB_DIR/" 2>/dev/null || true
        # Ensure there's a libdvdread.so symlink
        if [ ! -f "$LIB_DIR/libdvdread.so" ]; then
            DVDREAD_VERSIONED=$(ls "$LIB_DIR"/libdvdread.so.* 2>/dev/null | head -1)
            [ -n "$DVDREAD_VERSIONED" ] && ln -sf "$(basename "$DVDREAD_VERSIONED")" "$LIB_DIR/libdvdread.so"
        fi
        DVDREAD_FOUND=true
        echo "  Copied libdvdread from $libdir"
        break
    fi
done

if [ "$DVDREAD_FOUND" = false ]; then
    echo "  WARNING: libdvdread not found (optional — needed for DVD extraction)"
    echo "  Install with: sudo apt install libdvdread-dev"
fi

for lib in "$LIB_DIR"/libdvdread*.so*; do
    [ -f "$lib" ] && [ ! -L "$lib" ] && patchelf --set-rpath '$ORIGIN' "$lib" 2>/dev/null || true
done

# ============================================================================
# Final RPATH verification
# ============================================================================
echo ""
echo "=== Verifying RPATHs ==="

RPATH_ISSUES=0
for so_file in $(find "$DEPS_DIR" -name "*.so" -o -name "*.so.*" | grep -v __pycache__); do
    [ -L "$so_file" ] && continue
    MISSING=$(ldd "$so_file" 2>/dev/null | grep "not found" || true)
    if [ -n "$MISSING" ]; then
        echo "  WARNING: $(basename "$so_file") has missing deps:"
        echo "    $MISSING"
        RPATH_ISSUES=$((RPATH_ISSUES + 1))
    fi
done

if [ "$RPATH_ISSUES" -eq 0 ]; then
    echo "  All RPATHs OK"
fi

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
for plugin in "$PLUGINS_DIR"/*.so; do
    if [ -f "$plugin" ]; then
        arch=$(file "$plugin" | grep -oE '(x86-64|aarch64|x86_64|ARM aarch64)' | head -1)
        name=$(basename "$plugin")
        echo "  $name: $arch"
    fi
done

echo ""
echo "vspipe:"
file "$DEPS_DIR/vapoursynth/vspipe-bin"

echo ""
echo "=== Summary ==="
PLUGIN_COUNT=$(ls -1 "$PLUGINS_DIR"/*.so 2>/dev/null | wc -l | tr -d ' ')
echo "Total plugins: $PLUGIN_COUNT"

if [ ${#FAILED_PLUGINS[@]} -gt 0 ]; then
    echo ""
    echo "Failed plugins: ${FAILED_PLUGINS[*]}"
fi

echo ""
echo "Installation complete: $DEPS_DIR"
echo ""
echo "To test:"
echo "  LD_LIBRARY_PATH='$DEPS_DIR/vapoursynth:$DEPS_DIR/python/lib:$DEPS_DIR/lib' \\"
echo "  VAPOURSYNTH_PLUGIN_PATH='$PLUGINS_DIR' \\"
echo "  PYTHONPATH='$PYTHON_PACKAGES_DIR' \\"
echo "  '$DEPS_DIR/vapoursynth/vspipe' --version"
