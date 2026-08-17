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
    fftw boost libdvdread
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
# Build redistributable support libraries from source (x64 only, issue #39)
# ============================================================================
# On the only available Intel runner (macos-15-intel) `brew install` pours
# minos 14/15 bottles that won't load on macOS 12. Build the few libraries we
# *bundle* from source so they inherit MACOSX_DEPLOYMENT_TARGET (12.0):
#   zimg/fftw/libdvdread     - stable C ABIs; dropped in over the Homebrew
#                              copies just before the repoint pass.
#   boost (filesystem,atomic) - ABI-sensitive, so the OpenCL plugins
#                              (nnedi3cl/knlmeanscl) are ALSO compiled against
#                              this build via BOOST_ROOT="$SRCLIB" below.
# arm64 is untouched (no deployment-target pin -> this whole block is skipped).
SRCLIB="$BUILD_DIR/srclib"
if [ "$ARCH" = "x86_64" ]; then
    echo ""
    echo "=== Building support libraries from source (target $MACOS_MIN_VERSION) ==="
    NPROC=$(sysctl -n hw.ncpu)
    SRC_TMP="$BUILD_DIR/srclib-src"
    mkdir -p "$SRCLIB" "$SRC_TMP"
    cd "$SRC_TMP"

    # fftw 3.3.10, single precision + threads -> libfftw3f.3 + libfftw3f_threads.3
    echo "  Building fftw (3.3.10, float)..."
    curl -fsSL "https://www.fftw.org/fftw-3.3.10.tar.gz" -o fftw.tar.gz
    tar xzf fftw.tar.gz && cd fftw-3.3.10
    ./configure --prefix="$SRCLIB" --enable-float --enable-threads --enable-shared \
        --disable-static --disable-fortran --disable-doc -q
    make -j"$NPROC" >/dev/null && make install >/dev/null
    cd "$SRC_TMP"

    # zimg 3.0.5 -> libzimg.2.dylib (VapourSynth core resize; stable C ABI)
    echo "  Building zimg (3.0.5)..."
    curl -fsSL "https://github.com/sekrit-twc/zimg/archive/refs/tags/release-3.0.5.tar.gz" -o zimg.tar.gz
    tar xzf zimg.tar.gz && cd zimg-release-3.0.5
    ./autogen.sh
    ./configure --prefix="$SRCLIB" --enable-shared --disable-static -q
    make -j"$NPROC" >/dev/null && make install >/dev/null
    cd "$SRC_TMP"

    # libdvdread 6.1.3 -> libdvdread.dylib (worker dlopens it, resolves by name)
    echo "  Building libdvdread (6.1.3)..."
    curl -fsSL "https://download.videolan.org/pub/videolan/libdvdread/6.1.3/libdvdread-6.1.3.tar.bz2" -o dvdread.tar.bz2
    tar xjf dvdread.tar.bz2 && cd libdvdread-6.1.3
    ./configure --prefix="$SRCLIB" --enable-shared --disable-static -q
    make -j"$NPROC" >/dev/null && make install >/dev/null
    cd "$SRC_TMP"

    # boost 1.85.0, just filesystem + atomic -> libboost_filesystem/_atomic.dylib
    echo "  Building boost (1.85.0: filesystem, atomic)..."
    curl -fsSL "https://archives.boost.io/release/1.85.0/source/boost_1_85_0.tar.bz2" -o boost.tar.bz2
    tar xjf boost.tar.bz2 && cd boost_1_85_0
    ./bootstrap.sh --with-libraries=filesystem,atomic --prefix="$SRCLIB" >/dev/null
    ./b2 -j"$NPROC" --with-filesystem --with-atomic link=shared \
        cxxflags="-mmacosx-version-min=$MACOS_MIN_VERSION" \
        linkflags="-mmacosx-version-min=$MACOS_MIN_VERSION" \
        install >/dev/null
    cd "$BUILD_DIR"

    # boost is linked by the OpenCL plugins built later; give it an @rpath id so
    # those plugins record a *repointable* reference (the repoint pass skips refs
    # that are already @loader_path/...). zimg/fftw/dvdread get their ids
    # normalized when they're dropped into the bundle.
    for b in libboost_filesystem libboost_atomic; do
        [ -f "$SRCLIB/lib/$b.dylib" ] && install_name_tool -id "@rpath/$b.dylib" "$SRCLIB/lib/$b.dylib"
    done

    echo "  Built support libs:"
    ls -1 "$SRCLIB"/lib/*.dylib 2>/dev/null | sed 's/^/    /'
fi

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

VS_TAG="R78"
VS_BUILD_DIR="$BUILD_DIR/vapoursynth"
VS_INSTALL_DIR="$BUILD_DIR/vapoursynth-install"

if [ "$FORCE" = true ] || [ ! -f "$DEPS_DIR/vapoursynth/libvapoursynth.dylib" ]; then
    echo "  Cloning VapourSynth $VS_TAG..."
    rm -rf "$VS_BUILD_DIR"
    git clone --depth 1 --branch "$VS_TAG" https://github.com/vapoursynth/vapoursynth.git "$VS_BUILD_DIR" 2>/dev/null || \
    git clone --depth 1 https://github.com/vapoursynth/vapoursynth.git "$VS_BUILD_DIR"

    cd "$VS_BUILD_DIR"

    # ------------------------------------------------------------------------
    # zimg API guard (backport of upstream 37eed3dd)
    # ------------------------------------------------------------------------
    # R78 reads zimg's chromatic_adaptation field unconditionally, but that
    # field only exists in a zimg newer than the current release (3.0.6), so
    # R78 does not compile against any released zimg. Upstream fixed it two
    # days after tagging; this is that fix. Hard-fail rather than fall over in
    # the compiler with a confusing error.
    git apply "$SCRIPT_DIR/patches/vapoursynth-r78-zimg-api-guard.patch" || {
        echo "  ERROR: patches/vapoursynth-r78-zimg-api-guard.patch did not apply." >&2
        echo "  If VapourSynth has moved past R78 the fix is already upstream — drop it." >&2
        exit 1
    }
    echo "  Applied the zimg chromatic_adaptation API guard"

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
        # R73 carried doubleToString() in both files; R78 has it only in
        # vsjson.cpp. Patch whichever files actually contain it, so this neither
        # hard-fails on a file that no longer needs it nor silently skips one
        # that does.
        for vs_src in $(grep -rl "std::to_chars" src/vspipe/ 2>/dev/null); do
            VS_SRC="$vs_src" python3 - <<'PYEOF'
import os, re, sys
path = os.environ["VS_SRC"]
with open(path) as f:
    content = f.read()

# R78 uses two call forms: vsjson.cpp passes chars_format::fixed, vspipe.cpp
# adds a precision argument. Match either, rather than one literal string.
m = re.search(
    r"[ \t]*auto res = std::to_chars\(buffer, buffer \+ sizeof\(buffer\), v, std::chars_format::fixed[^)]*\);\n"
    r"[ \t]*return std::string\(buffer, res\.ptr - buffer\);",
    content)
old = m.group(0) if m else None
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

if old is None:
    if "issue #39" in content:
        print(f"    {path}: already patched")
        sys.exit(0)
    print(f"    ERROR: expected to_chars pattern not found in {path}", file=sys.stderr)
    sys.exit(1)

content = content.replace(old, new, 1)
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
    "$PYTHON_BIN" -m pip install --quiet cython meson

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
    # meson looks for a "cython3" program before "cython", so apt's cython3
    # (0.29 on jammy) wins over the Cython 3.x we just installed into the
    # embedded interpreter no matter how PATH is ordered — and R78's
    # vapoursynth.pyx uses Cython 3 syntax, failing with "Syntax error in C
    # variable declaration" on `noexcept`. Provide both names as wrappers that
    # run the module, which also sidesteps the console script's baked-in
    # shebang (it points at the machine that built the interpreter).
    for cy in cython cython3; do
        cat > "$PYTHON_DIR/bin/$cy" << CYEOF
#!/bin/bash
exec "$PYTHON_DIR/bin/python3" -m cython "\$@"
CYEOF
        chmod +x "$PYTHON_DIR/bin/$cy"
    done

    # Run meson with the EMBEDDED python, not whatever meson happens to be
    # installed under. R78 locates Python with
    # `import('python').find_installation()`, which resolves to the interpreter
    # meson itself is running as — PATH does not influence it, and the
    # -Dpython3_bin option that used to override it was removed. Left alone,
    # meson picks the runner's system python: on Linux that has no development
    # headers, so configuration dies with "Header 'Python.h' could not be
    # found", and on macOS it silently builds and installs against Homebrew's
    # python instead of the one we ship.
    "$PYTHON_BIN" -m mesonbuild.mesonmain setup build \
        --prefix="$VS_INSTALL_DIR" \
        --buildtype=release \
        -Dlibdir=lib

    echo "  Building VapourSynth..."
    PATH="$PYTHON_DIR/bin:$PATH" ninja -C build
    PATH="$PYTHON_DIR/bin:$PATH" ninja -C build install

    echo "  Copying VapourSynth files..."
    # Copy from the build directory, not the install prefix. R74 turned
    # VapourSynth into a Python package ("pip install vapoursynth"), so
    # `ninja install` now puts vspipe and every library under
    # <prefix>/<python-site-packages>/vapoursynth/ rather than <prefix>/bin and
    # <prefix>/lib. The build directory is flat and does not depend on which
    # Python did the install, so it is the stable place to copy from.
    VS_BUILT="$VS_BUILD_DIR/build"

    cp "$VS_BUILT/vspipe" "$DEPS_DIR/vapoursynth/vspipe-bin"
    chmod +x "$DEPS_DIR/vapoursynth/vspipe-bin"

    # ------------------------------------------------------------------------
    # deps/<platform>/vapoursynth/ IS the Python package
    # ------------------------------------------------------------------------
    # R78 ships VapourSynth as a Python package, and vsscript resolves the
    # Python library through a config file keyed by the ABSOLUTE PATH of
    # libvsscript. That config is written by `vapoursynth config`, which records
    # the libvsscript belonging to the imported package. So the copy vspipe-bin
    # loads and the copy the module reports have to be the same file, or every
    # script fails with "Python executable and library path couldn't be
    # determined despite automatic configuration".
    #
    # Keeping the directory name `vapoursynth` and putting the platform dir on
    # PYTHONPATH satisfies that without moving anything the app already knows
    # about. It also puts the plugins at <libdir>/plugins, which R78 autoloads,
    # so VAPOURSYNTH_EXTRA_PLUGIN_PATH is no longer set on this platform — with
    # both, every plugin loads twice and warns about it.
    cp "$VS_BUILT/libvapoursynth.4.dylib"      "$DEPS_DIR/vapoursynth/libvapoursynth.4.dylib"
    ln -sf libvapoursynth.4.dylib              "$DEPS_DIR/vapoursynth/libvapoursynth.dylib"
    # vapoursynth-script was renamed vsscript in R78, and is unversioned.
    cp "$VS_BUILT/libvsscript.dylib"           "$DEPS_DIR/vapoursynth/libvsscript.dylib"
    # R78 split every core filter (std, resize, ...) out of libvapoursynth into
    # this module. Without it the core namespaces are simply absent and every
    # job fails at script evaluation.
    cp "$VS_BUILT/libvapoursynthfilters.dylib" "$DEPS_DIR/vapoursynth/libvapoursynthfilters.dylib"
    cp "$VS_BUILT/vapoursynth.abi3.so"         "$DEPS_DIR/vapoursynth/"
    # The pure-Python half of the package. Without it `vapoursynth config`
    # cannot run and vsscript's automatic configuration has nothing to call.
    cp "$VS_BUILD_DIR/src/py/"*.py "$VS_BUILD_DIR/src/py/vapoursynth.pyi" \
        "$DEPS_DIR/vapoursynth/" 2>/dev/null || \
        cp "$VS_BUILD_DIR/src/py/"*.py "$DEPS_DIR/vapoursynth/"

    # vsscript self-configures by shelling out to a `vapoursynth` executable.
    # A from-source build creates no console script, so provide one.
    cat > "$PYTHON_DIR/bin/vapoursynth" << 'SHIM_EOF'
#!/bin/bash
DEPS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PYTHONHOME="$DEPS_ROOT/python"
export PYTHONPATH="$DEPS_ROOT:$DEPS_ROOT/python-packages:${PYTHONPATH:-}"
exec "$DEPS_ROOT/python/bin/python3" -m vapoursynth "$@"
SHIM_EOF
    chmod +x "$PYTHON_DIR/bin/vapoursynth"

    # Copy zimg from Homebrew (will fix paths to be relative)
    cp "$BREW_PREFIX/lib/libzimg.2.dylib" "$DEPS_DIR/vapoursynth/libzimg.dylib"

    echo "  Fixing library paths..."
    cd "$DEPS_DIR/vapoursynth"

    # Fix all library install names to be relative
    for lib in *.dylib; do
        install_name_tool -id "@loader_path/$lib" "$lib" 2>/dev/null || true
    done

    # Everything that links libvapoursynth or libpython now sits in this one
    # directory (R78 ships them as a Python package), so fix them in one pass.
    #
    # The python reference is "/install/lib/libpython3.X.dylib" —
    # python-build-standalone bakes that absolute path in as the install name,
    # and it does not exist on any machine. Rewriting it is what makes the
    # bundle self-contained; miss it and vspipe dies at load with
    # "Library not loaded: /install/lib/libpython3.12.dylib". Both that and the
    # build-tree path are rewritten, so it does not matter which the linker
    # recorded.
    for macho in libvsscript.dylib libvapoursynthfilters.dylib vapoursynth.abi3.so \
                 vspipe-bin libvapoursynth-script.dylib libvapoursynth-script.4.dylib; do
        [ -e "$macho" ] || continue
        for vs_ref in "$VS_INSTALL_DIR/lib/libvapoursynth.4.dylib" "@rpath/libvapoursynth.4.dylib"; do
            install_name_tool -change "$vs_ref" \
                "@loader_path/libvapoursynth.4.dylib" "$macho" 2>/dev/null || true
        done
        # vspipe links vsscript through @rpath. That happens to resolve via the
        # DYLD_LIBRARY_PATH the wrapper and the worker both set, so it "works"
        # without this — but only because of the environment, which makes the
        # binary non-relocatable and the failure environment-dependent.
        install_name_tool -change "@rpath/libvsscript.dylib" \
            "@loader_path/libvsscript.dylib" "$macho" 2>/dev/null || true
        for py_ref in "/install/lib/libpython${PYTHON_MAJOR_MINOR}.dylib" \
                      "$PYTHON_DIR/lib/libpython${PYTHON_MAJOR_MINOR}.dylib"; do
            install_name_tool -change "$py_ref" \
                "@loader_path/../python/lib/libpython${PYTHON_MAJOR_MINOR}.dylib" "$macho" 2>/dev/null || true
        done
    done

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
export PYTHONPATH="$DEPS_ROOT:$DEPS_ROOT/python-packages:${PYTHONPATH:-}"

# Add our lib directories to dylib search path
export DYLD_LIBRARY_PATH="$SCRIPT_DIR:$DEPS_ROOT/python/lib:${DYLD_LIBRARY_PATH:-}"

# R74 removed the config-file mechanism entirely (UserPluginDir /
# AutoloadUserPluginDir / VAPOURSYNTH_CONF_PATH no longer exist). Plugins live
# at <libdir>/plugins and are autoloaded, so no plugin variable is needed here.
#
# vsscript resolves the Python library through a config keyed by the libvsscript
# path and writes it on first use via the `vapoursynth` shim on PATH, so give it
# somewhere writable to put it.
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$DEPS_ROOT/config}"
mkdir -p "$XDG_CONFIG_HOME" 2>/dev/null || true

exec "$SCRIPT_DIR/vspipe-bin" "$@"
WRAPPER_EOF
    chmod +x "$DEPS_DIR/vapoursynth/vspipe"

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

    # Some plugins' meson.build locates the VapourSynth headers via a run_command
    # the clean build machine can't satisfy, in one of two forms:
    #   (a) `import vapoursynth as vs; print(vs.get_include())` in the host python
    #       (e.g. mvtools, bm3d, eedi3m) - the host python has no `vapoursynth`
    #       module (the runtime VS module is built against our embedded python).
    #   (b) `run_command('vapoursynth', 'get-include', ...)` - invokes the
    #       `vapoursynth` console script, which isn't on PATH here (e.g. CAS, which
    #       upstream switched to this form). Both end in `.stdout().strip()`.
    # Replace either probe with the from-source VS include dir (same trick used
    # for vivtc below). Match the program form too, not just "import vapoursynth".
    if [ -n "$VS_INC_DIR" ] && [ -f meson.build ] \
       && grep -qE "import vapoursynth|run_command\('vapoursynth'" meson.build; then
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
# R78 installs VapourSynth as a Python package, so its pkgconfig and
# include directories live under <prefix>/<site-packages>/vapoursynth/
# rather than <prefix>/lib and <prefix>/include. Locate them instead of
# assuming: with the wrong path every plugin resolving VapourSynth via
# pkg-config silently fails to configure, and the bundle comes out with
# most of its plugins missing.
VS_PC_DIR="$(dirname "$(find "$VS_INSTALL_DIR" -name vapoursynth.pc 2>/dev/null | head -1)")"
VS_INC_DIR="$(dirname "$(find "$VS_INSTALL_DIR" -name 'VapourSynth4.h' 2>/dev/null | head -1)")"
# R78's generated vapoursynth.pc dropped the libdir variable that R73's had.
# Plugins whose meson.build does
#   vapoursynth_dep.get_variable(pkgconfig: 'libdir')
# to decide where to install (addgrain, tcanny) then fail configuration with
# "Could not get pkg-config variable and no default provided". The value is only
# used as an install prefix and we copy the built dylib ourselves, so any sane
# path restores the lookup.
if [ -n "$VS_PC_DIR" ] && [ -f "$VS_PC_DIR/vapoursynth.pc" ] \
   && ! grep -q '^libdir=' "$VS_PC_DIR/vapoursynth.pc"; then
    awk '{print} /^includedir=/ && !done {print "libdir=${prefix}/lib"; done=1}' \
        "$VS_PC_DIR/vapoursynth.pc" > "$VS_PC_DIR/vapoursynth.pc.tmp" \
        && mv "$VS_PC_DIR/vapoursynth.pc.tmp" "$VS_PC_DIR/vapoursynth.pc"
    echo "  Added libdir to vapoursynth.pc (R78 omits it)"
fi

# R78 installs only the API4 headers, but several plugins we build still
# #include <VapourSynth.h> (API3) — api3 support remains in the core, just the
# headers stopped being installed. They are still in the source tree, so top up
# the include dir from there; without this nnedi3, addgrain, awarpsharp2, ctmf
# and the OpenCL pair fail with "'VapourSynth.h' file not found".
if [ -n "$VS_INC_DIR" ] && [ -d "$VS_BUILD_DIR/include" ]; then
    for hdr in "$VS_BUILD_DIR/include/"*.h; do
        [ -f "$hdr" ] || continue
        [ -f "$VS_INC_DIR/$(basename "$hdr")" ] || cp "$hdr" "$VS_INC_DIR/"
    done
fi

# Some plugins spell their includes <vapoursynth/VapourSynth.h> rather than
# <VapourSynth.h> — retinex (API3) and bifrost (API4) both do — so they need an
# include root whose CHILD is a directory called vapoursynth. Mirror the
# permanent symlink farm download-deps-linux.sh keeps, so that on both platforms
# a single -I"$VS_INC_DIR" satisfies either include style and no plugin has to
# stage a private include tree.
#
# retinex resolves its headers through pkg-config, which yields this same
# directory, so it needs no build-command change once the subdirectory exists.
if [ -n "$VS_INC_DIR" ]; then
    mkdir -p "$VS_INC_DIR/vapoursynth"
    for hdr in "$VS_INC_DIR"/*.h; do
        [ -f "$hdr" ] || continue
        ln -sf "../$(basename "$hdr")" "$VS_INC_DIR/vapoursynth/$(basename "$hdr")"
    done
    [ -f "$VS_INC_DIR/vapoursynth/VapourSynth.h" ] || \
        echo "  WARNING: no API3 header to link into $VS_INC_DIR/vapoursynth (retinex will fail)"
fi

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
           && PKG_CONFIG_PATH="$VS_PC_DIR:${PKG_CONFIG_PATH:-}" BOOST_ROOT="$SRCLIB" \
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
           && PKG_CONFIG_PATH="$VS_PC_DIR:${PKG_CONFIG_PATH:-}" BOOST_ROOT="$SRCLIB" \
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
if [ "$FORCE" = true ] || [ ! -f "$PLUGINS_DIR/libfmtconv.dylib" ]; then
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

fi  # end plugin arch split (x86_64 pre-built / arm64 from-source)

# The three plugins below are built from source on BOTH arches, so they sit
# outside the arch split above. They started inside its arm64 branch, where
# x64 never reached them and the packaging guard failed on all three missing
# dylibs. x64 takes pre-built binaries for most plugins, but Stefan-Olt ships
# none of these, and building them is cheap: two single C files and one small
# meson project. MACOSX_DEPLOYMENT_TARGET is exported near the top, so the x64
# builds inherit the 12.0 floor and pass the minos guard (issue #39).

# FluxSmooth (core.flux.SmoothT / SmoothST). Also what havsfunc's STPresso calls
# internally — without this plugin STPresso raises "No attribute with the name
# flux exists", which is why it is not offered without it.
#
# Pinned to v2, the newest tag with a published Windows binary. Windows has no
# from-source build path here (download-deps-windows.ps1 only fetches release
# archives), so every platform tracks the version Windows can get; a version
# skew would make the same job denoise differently per OS.
#
# Built by invoking the compiler directly rather than through its autotools
# build: it is one C file, and autoconf/automake/libtool are not otherwise
# required by any deps build.
FLUXSMOOTH_TAG="v2"
if [ "$FORCE" = true ] || [ ! -f "$PLUGINS_DIR/libfluxsmooth.dylib" ]; then
    echo ""
    echo "=== Building fluxsmooth ($FLUXSMOOTH_TAG) ==="
    rm -rf fluxsmooth
    if git clone --depth 1 --branch "$FLUXSMOOTH_TAG" -q \
        https://github.com/dubhater/vapoursynth-fluxsmooth.git fluxsmooth 2>/dev/null \
       && cc -std=c99 -O2 -fPIC -shared \
            -o "$PLUGINS_DIR/libfluxsmooth.dylib" \
            fluxsmooth/src/fluxsmooth.c -I"$VS_INC_DIR"; then
        codesign -s - -f "$PLUGINS_DIR/libfluxsmooth.dylib" 2>/dev/null || true
        echo "  Built fluxsmooth -> libfluxsmooth.dylib"
        BUILT_PLUGINS+=("fluxsmooth")
    else
        echo "  Failed to build fluxsmooth"
        FAILED_PLUGINS+=("fluxsmooth")
    fi
else
    echo "  fluxsmooth already exists, skipping"
fi

# Bifrost (core.bifrost.Bifrost) - temporal rainbow / dot-crawl removal for
# composite captures. Pinned to v3.0, the newest tag with a published Windows
# binary; see the fluxsmooth note above for why every platform tracks that.
#
# Its source is one C file, so it is compiled directly rather than through its
# autotools build — no autoconf/automake/libtool needed in CI. It includes
# <vapoursynth/VapourSynth4.h>, so the include path has to be the PARENT of a
# directory called vapoursynth — which is what the symlink farm created next to
# VS_INC_DIR above provides.
BIFROST_TAG="v3.0"
if [ "$FORCE" = true ] || [ ! -f "$PLUGINS_DIR/libbifrost.dylib" ]; then
    echo ""
    echo "=== Building bifrost ($BIFROST_TAG) ==="
    rm -rf bifrost
    if git clone --depth 1 --branch "$BIFROST_TAG" -q \
        https://github.com/dubhater/vapoursynth-bifrost.git bifrost 2>/dev/null \
       && cc -std=c99 -O2 -fPIC -shared \
            -o "$PLUGINS_DIR/libbifrost.dylib" \
            bifrost/src/bifrost.c -I"$VS_INC_DIR"; then
        codesign -s - -f "$PLUGINS_DIR/libbifrost.dylib" 2>/dev/null || true
        echo "  Built bifrost -> libbifrost.dylib"
        BUILT_PLUGINS+=("bifrost")
    else
        echo "  Failed to build bifrost"
        FAILED_PLUGINS+=("bifrost")
    fi
else
    echo "  bifrost already exists, skipping"
fi

# Retinex (core.retinex.MSRCP) - multi-scale retinex, used here to lift shadow
# detail out of underexposed footage. Pinned to r4, the newest tag with a
# published Windows binary. Ordinary meson build; it finds the VapourSynth
# headers through pkg-config, which build_plugin already points at our
# from-source install.
build_plugin "retinex" \
    "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-Retinex.git" \
    "libretinex.dylib" \
    "meson setup build --buildtype=release && ninja -C build"

# zsmooth (core.zsmooth.CCD - chroma denoiser; also Cnr4 and a set of
# RemoveGrain/TemporalMedian-family filters).
#
# Keep ZSMOOTH_VERSION in step across download-deps-{macos,linux}.sh and
# download-deps-windows.ps1 — a version skew would make the same job produce
# different chroma per OS.
ZSMOOTH_VERSION="0.19.0"

if [ "$ARCH" = "arm64" ]; then
    # arm64 takes the author's build: it is minos 13, comfortably under this
    # arch's 15.0 target.
    download_prebuilt_plugin "zsmooth" "libzsmooth.dylib" \
        "https://github.com/adworacz/zsmooth/releases/download/${ZSMOOTH_VERSION}/zsmooth-aarch64-macos.zip"
else
    # x64 builds from source (issue #39). The author's x86_64 build is minos
    # 13.0, and this bundle targets 12.0, so the pre-built binary is rejected by
    # the minos guard at the end of this script — it would fail to load on
    # Monterey with a dyld error, which is the exact failure #39 was opened for.
    # Same reason zimg/fftw/boost are built from source in the x64 branch above.
    #
    # zsmooth is written in Zig, so this needs a Zig toolchain. It is fetched
    # here rather than installed globally: it is used for this one plugin, and
    # pinning it keeps the build reproducible. ZIG_VERSION must satisfy
    # zsmooth's `minimum_zig_version` (build.zig.zon) — 0.15.2 for zsmooth
    # 0.19.0. `zig build` also fetches zsmooth's own Zig dependencies
    # (vapoursynth headers, fftw), so this step needs network access.
    ZIG_VERSION="0.15.2"
    echo ""
    echo "=== Building zsmooth from source (x64, targeting macOS $MACOS_MIN_VERSION) ==="
    if [ "$FORCE" = true ] || [ ! -f "$PLUGINS_DIR/libzsmooth.dylib" ]; then
        # Subshell so a failure here can't abort the whole script under `set -e`;
        # the file check below decides whether it worked.
        (
            set -e
            cd "$BUILD_DIR"
            rm -rf zig-toolchain zsmooth
            curl -fsSL -o zig.tar.xz \
                "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-macos-${ZIG_VERSION}.tar.xz"
            mkdir -p zig-toolchain
            tar -xf zig.tar.xz -C zig-toolchain --strip-components=1
            git clone --depth 1 --branch "$ZSMOOTH_VERSION" \
                https://github.com/adworacz/zsmooth.git zsmooth
            cd zsmooth
            # Zig needs a full x.y version here: "x86_64-macos.12" is rejected
            # as an invalid OS version, "x86_64-macos.12.0" is accepted. Tolerate
            # a bare major from a $MACOS_MIN_VERSION override.
            case "$MACOS_MIN_VERSION" in
                *.*) ZIG_MACOS_MIN="$MACOS_MIN_VERSION" ;;
                *)   ZIG_MACOS_MIN="${MACOS_MIN_VERSION}.0" ;;
            esac
            "$BUILD_DIR/zig-toolchain/zig" build \
                -Doptimize=ReleaseFast \
                -Dtarget="x86_64-macos.${ZIG_MACOS_MIN}"
            cp zig-out/lib/libzsmooth.dylib "$PLUGINS_DIR/libzsmooth.dylib"
        ) || true

        if [ -f "$PLUGINS_DIR/libzsmooth.dylib" ]; then
            install_name_tool -id "@loader_path/libzsmooth.dylib" \
                "$PLUGINS_DIR/libzsmooth.dylib" 2>/dev/null || true
            codesign -s - -f "$PLUGINS_DIR/libzsmooth.dylib" 2>/dev/null || true
            echo "  Built zsmooth -> libzsmooth.dylib"
        else
            echo "  Warning: failed to build zsmooth"
            FAILED_PLUGINS+=("zsmooth")
        fi
        rm -rf "$BUILD_DIR/zig-toolchain" "$BUILD_DIR/zsmooth" "$BUILD_DIR/zig.tar.xz"
    else
        echo "  zsmooth already exists, skipping"
    fi
fi

# ============================================================================
# Bwdif / FillBorders / RemoveDirt / DeDot / LGhost
# ============================================================================
# All five sit OUTSIDE the arch split above (see the fluxsmooth note): a block
# placed inside the arm64 branch never runs on x64, which is how three plugins
# once shipped missing from the Intel bundle. Each one below picks its own
# per-arch source where the arches differ, in the same shape as TemporalMedian
# and zsmooth.

# Bwdif (core.bwdif.Bwdif) — BobWeaver deinterlacer, ported from FFmpeg's
# libavfilter. Taken from the PyPI wheel: upstream publishes no GitHub release
# assets, and the wheel is just a zip holding vapoursynth/plugins/bwdif.dylib.
# Unlike akarin's wheel it bundles no private dylibs — it links only
# /usr/lib/libc++ and libSystem — so nothing needs repointing or staging into
# lib/. Wheel tags differ per arch (macosx_10_15_x86_64 / macosx_11_0_arm64),
# both comfortably under this bundle's floor on either arch.
BWDIF_VERSION="5.1"
if [ "$ARCH" = "arm64" ]; then
    BWDIF_WHEEL_TAG="macosx_11_0_arm64"
else
    BWDIF_WHEEL_TAG="macosx_10_15_x86_64"
fi
echo ""
echo "=== Downloading Bwdif $BWDIF_VERSION ==="
if [ "$FORCE" = true ] || [ ! -f "$PLUGINS_DIR/libbwdif.dylib" ]; then
    BWDIF_URL=$("$PYTHON_BIN" - "$BWDIF_VERSION" "$BWDIF_WHEEL_TAG" <<'PYEOF'
import json, sys, urllib.request
ver, tag = sys.argv[1], sys.argv[2]
d = json.load(urllib.request.urlopen(f"https://pypi.org/pypi/vapoursynth-bwdif/{ver}/json"))
print(next(f["url"] for f in d["urls"] if f["filename"].endswith(tag + ".whl")))
PYEOF
)
    rm -rf "$BUILD_DIR/bwdif" "$BUILD_DIR/bwdif.whl"
    mkdir -p "$BUILD_DIR/bwdif"
    # A wheel is a zip; take the plugin binary only, never pip install it into
    # the embedded interpreter.
    if curl -fL -o "$BUILD_DIR/bwdif.whl" "$BWDIF_URL" \
       && unzip -q "$BUILD_DIR/bwdif.whl" -d "$BUILD_DIR/bwdif" \
       && [ -f "$BUILD_DIR/bwdif/vapoursynth/plugins/bwdif.dylib" ]; then
        cp "$BUILD_DIR/bwdif/vapoursynth/plugins/bwdif.dylib" "$PLUGINS_DIR/libbwdif.dylib"
        chmod u+w "$PLUGINS_DIR/libbwdif.dylib"
        install_name_tool -id "@loader_path/libbwdif.dylib" "$PLUGINS_DIR/libbwdif.dylib" 2>/dev/null || true
        codesign -s - -f "$PLUGINS_DIR/libbwdif.dylib" 2>/dev/null || true
        echo "  Installed Bwdif -> libbwdif.dylib"
        BUILT_PLUGINS+=("bwdif")
    else
        echo "  Failed to install Bwdif"
        FAILED_PLUGINS+=("bwdif")
    fi
    rm -rf "$BUILD_DIR/bwdif" "$BUILD_DIR/bwdif.whl"
else
    echo "  Bwdif already exists, skipping"
fi

# FillBorders (core.fb.FillBorders) — fills dead edges left by a capture.
#
# Pinned to v2: v3 and v4 exist as tags but publish NO release assets, and
# download-deps-windows.ps1 has no from-source path, so every platform tracks
# the newest version Windows can get (the same rule fluxsmooth and bifrost
# follow). One C++ file including <VapourSynth.h> / <VSHelper.h> (API3), so it
# is compiled directly rather than through its autotools or meson build — no
# new toolchain in CI, and MACOSX_DEPLOYMENT_TARGET (exported near the top)
# gives the x64 build the 12.0 floor the minos guard demands.
FILLBORDERS_TAG="v2"
if [ "$FORCE" = true ] || [ ! -f "$PLUGINS_DIR/libfillborders.dylib" ]; then
    echo ""
    echo "=== Building FillBorders ($FILLBORDERS_TAG) ==="
    rm -rf fillborders
    # Fail loudly if the include variable is ever renamed: an empty one reaches
    # the compiler as a bare `-I` and the error says nothing about which
    # variable was wrong. Note this is VS_INC_DIR here and VS_INCLUDE_DIR in
    # download-deps-linux.sh — the two scripts do not share a vocabulary.
    : "${VS_INC_DIR:?VS_INC_DIR is unset — FillBorders cannot find the VapourSynth headers}"
    if git clone --depth 1 --branch "$FILLBORDERS_TAG" -q \
        https://github.com/dubhater/vapoursynth-fillborders.git fillborders 2>/dev/null \
       && c++ -std=c++11 -O2 -fPIC -shared \
            -o "$PLUGINS_DIR/libfillborders.dylib" \
            fillborders/src/fillborders.cpp -I"$VS_INC_DIR"; then
        install_name_tool -id "@loader_path/libfillborders.dylib" \
            "$PLUGINS_DIR/libfillborders.dylib" 2>/dev/null || true
        codesign -s - -f "$PLUGINS_DIR/libfillborders.dylib" 2>/dev/null || true
        echo "  Built FillBorders -> libfillborders.dylib"
        BUILT_PLUGINS+=("fillborders")
    else
        echo "  Failed to build FillBorders"
        FAILED_PLUGINS+=("fillborders")
    fi
else
    echo "  FillBorders already exists, skipping"
fi

# RemoveDirt (core.removedirt.RestoreMotionBlocks / SCSelect) — dirt and spot
# removal for film scans. Taken pre-built from Stefan-Olt/vs-plugin-build on
# both arches, the same source TemporalMedian uses. Both builds link only
# /usr/lib/libc++ and libSystem, and the x86_64 one is LC_VERSION_MIN_MACOSX
# 10.11, so it passes the STRICT_MIN_OS=1 guard at the end of this script.
if [ "$ARCH" = "arm64" ]; then
    REMOVEDIRT_URL="$STEFANOLT/com.vapoursynth.removedirt/v1.1/darwin-aarch64/2026-01-07T00.39.06%2B00.00Z/RemoveDirt-v1.1-darwin-aarch64.zip"
else
    REMOVEDIRT_URL="$STEFANOLT/com.vapoursynth.removedirt/v1.1/darwin-x86_64/2026-01-07T00.39.26%2B00.00Z/RemoveDirt-v1.1-darwin-x86_64.zip"
fi
echo ""
download_prebuilt_plugin "RemoveDirt" "libremovedirt.dylib" "$REMOVEDIRT_URL"

# DeDot (core.dedot.Dedot) — temporal cross-colour (rainbow) and cross-luma
# (dotcrawl) reduction for composite captures.
#
# arm64 takes the PyPI wheel; x64 must NOT. Both dedot wheels are built minos
# 15.0, and this bundle's Intel floor is 12.0 with STRICT_MIN_OS=1 — the wheel
# would fail the guard and, shipped anyway, would refuse to load on Monterey
# (issue #39). It is one C++ file with no SIMD and no dependencies, so the x64
# branch compiles it directly, exactly as zsmooth splits for the same reason.
# Wheel 3.0 and git tag v3 are the same release; keep the two in step.
DEDOT_VERSION="3.0"
DEDOT_TAG="v3"
echo ""
echo "=== Installing DeDot $DEDOT_VERSION ==="
if [ "$FORCE" = true ] || [ ! -f "$PLUGINS_DIR/libdedot.dylib" ]; then
    if [ "$ARCH" = "arm64" ]; then
        DEDOT_URL=$("$PYTHON_BIN" - "$DEDOT_VERSION" "macosx_15_0_arm64" <<'PYEOF'
import json, sys, urllib.request
ver, tag = sys.argv[1], sys.argv[2]
d = json.load(urllib.request.urlopen(f"https://pypi.org/pypi/vapoursynth-dedot/{ver}/json"))
print(next(f["url"] for f in d["urls"] if f["filename"].endswith(tag + ".whl")))
PYEOF
)
        rm -rf "$BUILD_DIR/dedot-whl" "$BUILD_DIR/dedot.whl"
        mkdir -p "$BUILD_DIR/dedot-whl"
        if curl -fL -o "$BUILD_DIR/dedot.whl" "$DEDOT_URL" \
           && unzip -q "$BUILD_DIR/dedot.whl" -d "$BUILD_DIR/dedot-whl" \
           && [ -f "$BUILD_DIR/dedot-whl/vapoursynth/plugins/dedot.dylib" ]; then
            cp "$BUILD_DIR/dedot-whl/vapoursynth/plugins/dedot.dylib" "$PLUGINS_DIR/libdedot.dylib"
            chmod u+w "$PLUGINS_DIR/libdedot.dylib"
            echo "  Installed DeDot (wheel) -> libdedot.dylib"
        fi
        rm -rf "$BUILD_DIR/dedot-whl" "$BUILD_DIR/dedot.whl"
    else
        : "${VS_INC_DIR:?VS_INC_DIR is unset — DeDot cannot find the VapourSynth headers}"
        rm -rf dedot
        if git clone --depth 1 --branch "$DEDOT_TAG" -q \
            https://github.com/dubhatervapoursynth/vapoursynth-dedot.git dedot 2>/dev/null \
           && c++ -std=c++17 -O2 -fPIC -shared \
                -o "$PLUGINS_DIR/libdedot.dylib" \
                dedot/src/dedot.cpp -I"$VS_INC_DIR"; then
            echo "  Built DeDot ($DEDOT_TAG) -> libdedot.dylib"
        fi
    fi

    if [ -f "$PLUGINS_DIR/libdedot.dylib" ]; then
        install_name_tool -id "@loader_path/libdedot.dylib" "$PLUGINS_DIR/libdedot.dylib" 2>/dev/null || true
        codesign -s - -f "$PLUGINS_DIR/libdedot.dylib" 2>/dev/null || true
        BUILT_PLUGINS+=("dedot")
    else
        echo "  Failed to install DeDot"
        FAILED_PLUGINS+=("dedot")
    fi
else
    echo "  DeDot already exists, skipping"
fi

# LGhost (core.lghost.LGhost) — luminance-ghost / edge-ghost (ringing)
# reduction, the classic fix for RF and long-cable analogue captures. Pinned to
# r1, the only tag upstream has published. Taken pre-built from
# Stefan-Olt/vs-plugin-build on both arches: its meson build compiles a stack of
# x86 SIMD translation units through VCL2, which is dead weight here, and both
# published dylibs link nothing outside /usr/lib.
if [ "$ARCH" = "arm64" ]; then
    LGHOST_URL="$STEFANOLT/com.holywu.lghost/r1/darwin-aarch64/2024-09-30T20.54.34%2B00.00Z/LGhost-r1-darwin-aarch64.zip"
else
    LGHOST_URL="$STEFANOLT/com.holywu.lghost/r1/darwin-x86_64/2024-09-30T20.57.30%2B00.00Z/LGhost-r1-darwin-x86_64.zip"
fi
echo ""
download_prebuilt_plugin "LGhost" "liblghost.dylib" "$LGHOST_URL"

# ============================================================================
# akarin — LLVM JIT for std.Expr (arm64 only)
# ============================================================================
# VapourSynth's own Expr JIT is wrapped in #ifdef VS_TARGET_CPU_X86, so on ARM
# every expression is walked once per pixel by a scalar interpreter. akarin has
# a real LLVM JIT that works on aarch64: measured 4.1x end to end on QTGMC Slow
# (11.5s -> 2.8s, 720x576, M1) and bit-identical to std.Expr on 45 of the 46
# expressions havsfunc actually generates.
#
# arm64 only, deliberately. The x64 wheel is macosx_14_0 while this bundle
# targets $MACOS_MIN_VERSION (issue #39), so shipping it would raise the Intel
# floor to macOS 14 — and x86 already has the JIT, so it loses nothing. The
# routing shim falls back to std.Expr wherever core.akarin is absent.
AKARIN_VERSION="1.4.1"
echo ""
echo "=== Downloading akarin $AKARIN_VERSION (LLVM JIT for std.Expr) ==="
if [ "$ARCH" = "x86_64" ]; then
    echo "  Skipped on x64: wheel is macosx_14_0, this bundle targets $MACOS_MIN_VERSION."
elif [ "$FORCE" = true ] || [ ! -f "$PLUGINS_DIR/libakarin.dylib" ]; then
    AK_URL=$("$PYTHON_BIN" - "$AKARIN_VERSION" "macosx_14_0_arm64" <<'PYEOF'
import json, sys, urllib.request
ver, tag = sys.argv[1], sys.argv[2]
d = json.load(urllib.request.urlopen(f"https://pypi.org/pypi/vapoursynth-akarin/{ver}/json"))
print(next(f["url"] for f in d["urls"] if f["filename"].endswith(tag + ".whl")))
PYEOF
)
    rm -rf "$BUILD_DIR/akarin" && mkdir -p "$BUILD_DIR/akarin" "$LIB_DIR"
    curl -L -o "$BUILD_DIR/akarin.whl" "$AK_URL"
    # A wheel is a zip; we want the plugin binary only, never a pip install into
    # the embedded interpreter.
    unzip -q "$BUILD_DIR/akarin.whl" -d "$BUILD_DIR/akarin"
    cp "$BUILD_DIR/akarin/vapoursynth/plugins/akarin/libakarin.dylib" "$PLUGINS_DIR/"
    cp "$BUILD_DIR/akarin"/vapoursynth_akarin.dylibs/*.dylib "$LIB_DIR/"
    chmod u+w "$PLUGINS_DIR/libakarin.dylib"

    # The wheel links its private libs as @loader_path/../../../vapoursynth_akarin.dylibs,
    # which is relative to the wheel's own layout and resolves to nothing here.
    # Repoint to lib/, matching the nnedi3cl -> boost convention. lib/ is
    # deliberately NOT on DYLD_LIBRARY_PATH, so the bundled libz cannot shadow
    # the system one for ffmpeg or anything else.
    install_name_tool -id "@loader_path/libakarin.dylib" "$PLUGINS_DIR/libakarin.dylib"
    for dep in $(otool -L "$PLUGINS_DIR/libakarin.dylib" | awk '/vapoursynth_akarin\.dylibs/{print $1}'); do
        install_name_tool -change "$dep" "@loader_path/../../lib/$(basename "$dep")" \
            "$PLUGINS_DIR/libakarin.dylib"
    done
    for f in "$BUILD_DIR/akarin"/vapoursynth_akarin.dylibs/*.dylib; do
        b=$(basename "$f")
        chmod u+w "$LIB_DIR/$b"
        install_name_tool -id "@loader_path/$b" "$LIB_DIR/$b" 2>/dev/null || true
        codesign -s - -f "$LIB_DIR/$b" 2>/dev/null || true
    done
    # Re-sign after install_name_tool or macOS SIGKILLs the loader (exit 137).
    codesign -s - -f "$PLUGINS_DIR/libakarin.dylib" 2>/dev/null || true

    if otool -L "$PLUGINS_DIR/libakarin.dylib" | grep -q "vapoursynth_akarin.dylibs"; then
        echo "  ERROR: libakarin.dylib still references the wheel-relative dylib path."
        echo "         It would load here and fail in the packaged bundle."
        exit 1
    fi
    rm -rf "$BUILD_DIR/akarin" "$BUILD_DIR/akarin.whl"
    echo "  Installed akarin -> libakarin.dylib"
else
    echo "  akarin already exists, skipping"
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
# this only ever hit macos-arm64 and linux-arm64. Still broken in upstream r31.
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

# Patch 6: prefer the NEON nnedi3 over the scalar znedi3 on ARM.
# znedi3's SIMD kernels are x86-only, so the ARM bundles build it with X86=0 and
# it runs fully scalar (PredictorC / PrescreenerOldC). The bundled dubhater
# nnedi3 ships real NEON kernels and is 6.3x faster for the same call — measured
# on an M1, QTGMC Slow, 400 frames of 720x576: 37.8s vs 5.95s of CPU, which is
# 30% of the whole arm64 QTGMC cost. havsfunc hardcodes znedi3 whenever it is
# present, so without this every ARM deinterlace pays that.
# Both plugins implement the same network from the same nnedi3_weights.bin and
# their signatures are identical for every argument havsfunc passes, so this is a
# drop-in swap: measured mean output difference 0.045/255 (worst pixel 27/255, on
# edges where the prescreener decision flips).
# The choice is made at runtime rather than by the build, so this patch text
# stays identical on every platform — x86 keeps using znedi3 exactly as before.
if '_nnedi3_impl' not in content:
    old_edi = "myNNEDI3 = core.znedi3.nnedi3 if hasattr(core, 'znedi3') else core.nnedi3.nnedi3"
    n_edi = content.count(old_edi)
    if n_edi:
        # Leading whitespace is untouched, so this covers all three call sites
        # (daa, santiag, QTGMC) despite their differing indentation.
        content = content.replace(old_edi, "myNNEDI3 = _nnedi3_impl()")
        content = content.replace('import math\n', 'import math\n' + '''

# Prefer the NEON nnedi3 over the scalar znedi3 on ARM (see download-deps-*).
def _nnedi3_impl():
    import platform
    if platform.machine().lower() in ('arm64', 'aarch64') and hasattr(core, 'nnedi3'):
        return core.nnedi3.nnedi3
    return core.znedi3.nnedi3 if hasattr(core, 'znedi3') else core.nnedi3.nnedi3
''')
        patches.append(f'ARM nnedi3 preference ({n_edi} sites)')

# Patch 7: route std.Expr through akarin's LLVM JIT.
# VapourSynth's Expr JIT is wrapped in #ifdef VS_TARGET_CPU_X86, so on ARM the
# whole bytecode program is walked once per pixel by ExprInterpreter::eval().
# Expr dominates arm64 QTGMC by a wide margin -- measured 550-640 CPU-seconds
# against the interpolator's 30 -- so this is the single biggest arm64 win
# available: 4.1x end to end on QTGMC Slow (11.5s -> 2.8s, M1, 720x576).
#
# havsfunc has 116 core.std.Expr call sites. Rewriting each one is unmaintainable
# against a file we already patch six other ways, so rebind the module's `core`
# to a proxy that swaps only .std.Expr and forwards everything else untouched.
#
# Verified against the 46 distinct expressions havsfunc actually generates
# (collected at runtime across every QTGMC preset plus daa/santiag/LSFmod/
# DeHalo_alpha/FineDehalo/SMDegrain/Deblock_QED/EdgeCleaner/YAHR): 45 are
# bit-identical. The one exception is the DeHalo_alpha/FineDehalo edge-MASK
# scale 'x {thmi} - {i} / 255 *', where a single input value lands on an exact
# .5 tie -- std.Expr rounds half-to-even, akarin rounds it down, so one level in
# a mask. macOS x64 has no akarin wheel compatible with our 12.0 floor and so
# keeps std.Expr; that platform therefore differs by that one level. It is far
# smaller than the ARM/x86 difference already accepted for nnedi3 vs znedi3
# (mean 0.045/255, worst pixel 27/255).
#
# The shim installs only when akarin is present, so where it is absent `core`
# stays the real core: no wrapper, no overhead, no behaviour change.
if '_akarin_expr' not in content:
    content = content.replace('import math\n', 'import math\n' + '''

# Route std.Expr through akarin's LLVM JIT where present (see download-deps-*).
_akarin_expr = getattr(getattr(core, 'akarin', None), 'Expr', None)
if _akarin_expr is not None:
    class _ExprStd:
        __slots__ = ('_std',)
        def __init__(self, std):
            self._std = std
        def __getattr__(self, name):
            return _akarin_expr if name == 'Expr' else getattr(self._std, name)

    class _ExprCore:
        __slots__ = ('_core', '_std')
        def __init__(self, c):
            self._core = c
            self._std = _ExprStd(c.std)
        def __getattr__(self, name):
            return self._std if name == 'std' else getattr(self._core, name)

    core = _ExprCore(core)
''')
    patches.append('akarin Expr routing')

if patches:
    with open(havsfunc_path, 'w') as f:
        f.write(content)
    print(f"  Patched: {', '.join(patches)}")
else:
    print("  Already patched")
EOF
fi

# ============================================================================
# Replace the bundled Homebrew support libs with the source builds (x64, #39)
# ============================================================================
# The copies above pulled Homebrew bottles (minos 14/15). Overwrite them with
# the minos-12 source builds from $SRCLIB so the x64 bundle loads on macOS 12.
# Done here -- after all plugin builds, before the repoint passes -- so the
# existing @loader_path rewiring and signing apply to them uniformly. The
# OpenCL plugins were already compiled against this same boost (BOOST_ROOT).
if [ "$ARCH" = "x86_64" ] && [ -d "$SRCLIB/lib" ]; then
    echo ""
    echo "=== Replacing Homebrew support libs with source builds (target $MACOS_MIN_VERSION) ==="
    # zimg sits next to libvapoursynth and isn't covered by the repoint passes,
    # so set its id explicitly here. libvapoursynth already refers to it via
    # @loader_path/libzimg.dylib, and zimg's C ABI (libzimg.2) is a safe drop-in.
    if [ -f "$SRCLIB/lib/libzimg.2.dylib" ]; then
        cp -f "$SRCLIB/lib/libzimg.2.dylib" "$DEPS_DIR/vapoursynth/libzimg.dylib"
        install_name_tool -id "@loader_path/libzimg.dylib" "$DEPS_DIR/vapoursynth/libzimg.dylib" 2>/dev/null || true
        codesign -s - -f "$DEPS_DIR/vapoursynth/libzimg.dylib" 2>/dev/null || true
        echo "  zimg -> vapoursynth/libzimg.dylib"
    fi
    # The remaining libs live in lib/; the repoint passes below normalize their
    # ids and inter-references. cp -f follows the versioned symlinks.
    for libname in libfftw3f.3.dylib libfftw3f_threads.3.dylib libdvdread.dylib \
                   libboost_filesystem.dylib libboost_atomic.dylib; do
        if [ -f "$SRCLIB/lib/$libname" ]; then
            cp -f "$SRCLIB/lib/$libname" "$LIB_DIR/$libname"
            codesign -s - -f "$LIB_DIR/$libname" 2>/dev/null || true
            echo "  $libname -> lib/$libname"
        else
            echo "  ERROR: expected source lib $SRCLIB/lib/$libname is missing" >&2
            exit 1
        fi
    done
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
SUPPORT_LIBS=(libfftw3f.3.dylib libfftw3f_threads.3.dylib libboost_filesystem.dylib libboost_atomic.dylib libdvdread.dylib)
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
for so_file in vapoursynth*.so; do
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

# Stamp the version the app expects, read from the single source of truth.
# A hardcoded value here (it used to be 1.0.0) makes checkDependencies() — an
# exact string compare against app/assets/deps-version.json — report a mismatch
# for a freshly built tree, and the app then downloads the published bundle
# straight over the top of it. Harmless while the local tree matched the
# release; destructive as soon as it is ahead, which is exactly what a deps
# upgrade branch creates.
EXPECTED_DEPS_VERSION=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['version'])" \
    "$PROJECT_ROOT/app/assets/deps-version.json" 2>/dev/null || echo "0.0.0")

cat > "$DEPS_DIR/version.json" << EOF
{
  "version": "$EXPECTED_DEPS_VERSION",
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
    echo "  - Homebrew bottles (zimg/fftw/boost/libdvdread): the macos-15 runner"
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
