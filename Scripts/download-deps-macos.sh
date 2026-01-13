#!/bin/bash
# Download dependencies for iDeinterlace on macOS
# Downloads VapourSynth, FFmpeg, plugins, and Python packages
#
# Prerequisites:
# - curl, unzip, tar
# - Homebrew (for some dependencies)
#
# Includes:
# - VapourSynth, FFmpeg, Python
# - Plugins: mvtools, nnedi3, znedi3, eedi3m, fmtconv, ffms2, miscfilters, dfttest
# - FFTW library (required by dfttest)
# - Python packages: havsfunc, mvsfunc, adjust
# - Patches havsfunc for API compatibility (mvtools, DFTTest, YCOCG)
#
# Usage: ./Scripts/download-deps-macos.sh [--arch arm64|x64]

set -e

ARCH=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
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
DEPS_DIR="$PROJECT_ROOT/deps/macos-$ARCH"
TEMP_DIR="$PROJECT_ROOT/deps/temp-macos"

echo "=== Downloading iDeinterlace Dependencies for macOS ($ARCH) ==="
echo ""
echo "Target directory: $DEPS_DIR"
echo ""

# Create directories
mkdir -p "$DEPS_DIR"
mkdir -p "$DEPS_DIR/vapoursynth/plugins"
mkdir -p "$DEPS_DIR/ffmpeg"
mkdir -p "$DEPS_DIR/python-packages"
mkdir -p "$TEMP_DIR"

cd "$TEMP_DIR"

# ============================================================================
# FFmpeg
# ============================================================================
echo "[1/7] Downloading FFmpeg..."
if [ "$ARCH" = "arm64" ]; then
    FFMPEG_URL="https://evermeet.cx/ffmpeg/getrelease/ffmpeg/zip"
    FFPROBE_URL="https://evermeet.cx/ffmpeg/getrelease/ffprobe/zip"
else
    FFMPEG_URL="https://evermeet.cx/ffmpeg/getrelease/ffmpeg/zip"
    FFPROBE_URL="https://evermeet.cx/ffmpeg/getrelease/ffprobe/zip"
fi

if [ ! -f "$DEPS_DIR/ffmpeg/ffmpeg" ]; then
    curl -L -o ffmpeg.zip "$FFMPEG_URL"
    unzip -o ffmpeg.zip -d "$DEPS_DIR/ffmpeg/"
    chmod +x "$DEPS_DIR/ffmpeg/ffmpeg"
    echo "    FFmpeg downloaded"
else
    echo "    FFmpeg already exists, skipping"
fi

if [ ! -f "$DEPS_DIR/ffmpeg/ffprobe" ]; then
    curl -L -o ffprobe.zip "$FFPROBE_URL"
    unzip -o ffprobe.zip -d "$DEPS_DIR/ffmpeg/"
    chmod +x "$DEPS_DIR/ffmpeg/ffprobe"
    echo "    FFprobe downloaded"
else
    echo "    FFprobe already exists, skipping"
fi

# ============================================================================
# VapourSynth via Homebrew (copy from system)
# ============================================================================
echo "[2/7] Setting up VapourSynth..."

# Determine Homebrew prefix
if [ "$ARCH" = "arm64" ]; then
    BREW_PREFIX="/opt/homebrew"
else
    BREW_PREFIX="/usr/local"
fi

# Check if VapourSynth is installed via Homebrew
if [ -f "$BREW_PREFIX/bin/vspipe" ]; then
    echo "    Copying vspipe from Homebrew..."
    cp "$BREW_PREFIX/bin/vspipe" "$DEPS_DIR/vapoursynth/"
    chmod +x "$DEPS_DIR/vapoursynth/vspipe"

    # Copy VapourSynth libraries
    if [ -f "$BREW_PREFIX/lib/libvapoursynth.dylib" ]; then
        cp "$BREW_PREFIX/lib/libvapoursynth.dylib" "$DEPS_DIR/vapoursynth/"
        cp "$BREW_PREFIX/lib/libvapoursynth-script.dylib" "$DEPS_DIR/vapoursynth/"
    fi

    echo "    VapourSynth copied from Homebrew"
else
    echo "    WARNING: VapourSynth not found in Homebrew"
    echo "    Please install: brew install vapoursynth"
    echo "    Then re-run this script"
fi

# ============================================================================
# VapourSynth Plugins
# ============================================================================
echo "[3/7] Downloading VapourSynth plugins..."

# Check if plugins exist in Homebrew
VS_PLUGINS_DIR="$BREW_PREFIX/lib/vapoursynth"
if [ -d "$VS_PLUGINS_DIR" ]; then
    echo "    Copying plugins from Homebrew..."
    for plugin in libmvtools.dylib libffms2.dylib libfmtconv.dylib libnnedi3.dylib \
                  libznedi3.dylib libnnedi3cl.dylib libmiscfilters.dylib libeedi3m.dylib \
                  libdfttest.dylib; do
        if [ -f "$VS_PLUGINS_DIR/$plugin" ]; then
            cp "$VS_PLUGINS_DIR/$plugin" "$DEPS_DIR/vapoursynth/plugins/"
            echo "        Copied $plugin"
        fi
    done
else
    echo "    WARNING: VapourSynth plugins directory not found"
    echo "    Please install plugins via Homebrew:"
    echo "        brew install vapoursynth-mvtools vapoursynth-ffms2"
fi

# ============================================================================
# FFTW Library (required by DFTTest)
# ============================================================================
echo "[3b/7] Setting up FFTW library..."

# Check for FFTW in Homebrew
FFTW_LIB="$BREW_PREFIX/lib/libfftw3f.dylib"
if [ -f "$FFTW_LIB" ]; then
    cp "$FFTW_LIB" "$DEPS_DIR/vapoursynth/"
    # Also copy versioned dylib if exists
    if [ -f "$BREW_PREFIX/lib/libfftw3f.3.dylib" ]; then
        cp "$BREW_PREFIX/lib/libfftw3f.3.dylib" "$DEPS_DIR/vapoursynth/"
    fi
    echo "    FFTW library copied from Homebrew"
else
    echo "    WARNING: FFTW not found in Homebrew"
    echo "    Please install: brew install fftw"
    echo "    FFTW is required for DFTTest plugin (used by SMDegrain prefilter=3, MCTemporalDenoise)"
fi

# ============================================================================
# NNEDI3 Weights
# ============================================================================
echo "[4/7] Downloading NNEDI3 weights..."
NNEDI3_WEIGHTS_URL="https://github.com/sekrit-twc/znedi3/raw/master/nnedi3_weights.bin"
if [ ! -f "$DEPS_DIR/vapoursynth/nnedi3_weights.bin" ]; then
    curl -L -o "$DEPS_DIR/vapoursynth/nnedi3_weights.bin" "$NNEDI3_WEIGHTS_URL"
    echo "    NNEDI3 weights downloaded"
else
    echo "    NNEDI3 weights already exist, skipping"
fi

# Also check Homebrew location
if [ -f "$BREW_PREFIX/share/nnedi3/nnedi3_weights.bin" ]; then
    cp "$BREW_PREFIX/share/nnedi3/nnedi3_weights.bin" "$DEPS_DIR/vapoursynth/"
fi

# ============================================================================
# Python Packages (havsfunc, mvsfunc, etc.)
# ============================================================================
echo "[5/7] Downloading Python packages..."

# havsfunc
HAVSFUNC_URL="https://raw.githubusercontent.com/HomeOfVapourSynthEvolution/havsfunc/master/havsfunc.py"
if [ ! -f "$DEPS_DIR/python-packages/havsfunc.py" ]; then
    curl -L -o "$DEPS_DIR/python-packages/havsfunc.py" "$HAVSFUNC_URL"
    echo "    havsfunc.py downloaded"
else
    echo "    havsfunc.py already exists, skipping"
fi

# mvsfunc
MVSFUNC_URL="https://raw.githubusercontent.com/HomeOfVapourSynthEvolution/mvsfunc/master/mvsfunc.py"
if [ ! -f "$DEPS_DIR/python-packages/mvsfunc.py" ]; then
    curl -L -o "$DEPS_DIR/python-packages/mvsfunc.py" "$MVSFUNC_URL"
    echo "    mvsfunc.py downloaded"
else
    echo "    mvsfunc.py already exists, skipping"
fi

# adjust
ADJUST_URL="https://raw.githubusercontent.com/HomeOfVapourSynthEvolution/adjust/master/adjust.py"
if [ ! -f "$DEPS_DIR/python-packages/adjust.py" ]; then
    curl -L -o "$DEPS_DIR/python-packages/adjust.py" "$ADJUST_URL" 2>/dev/null || echo "    adjust.py not available"
else
    echo "    adjust.py already exists, skipping"
fi

# ============================================================================
# Patch havsfunc for API compatibility
# ============================================================================
echo "[6/7] Patching havsfunc for API compatibility..."

HAVSFUNC="$DEPS_DIR/python-packages/havsfunc.py"
if [ -f "$HAVSFUNC" ]; then
    PATCHES_APPLIED=""

    # Patch 1: mvtools API (renamed _lambda/_global to lambda/global)
    if ! grep -q "_fix_mv_args" "$HAVSFUNC"; then
        echo "    Applying mvtools argument patch..."

        # Create the patch
        PATCH_CODE='
# Patch for mvtools API compatibility (added by iDeinterlace)
def _fix_mv_args(args):
    """Fix mvtools argument names (_lambda -> lambda, _global -> global)"""
    result = {}
    for k, v in args.items():
        if k == "_lambda":
            result["lambda"] = v
        elif k == "_global":
            result["global"] = v
        else:
            result[k] = v
    return result
'
        # Insert patch after imports (after "import vapoursynth as vs" line)
        sed -i.bak "/^import vapoursynth as vs/a\\
$PATCH_CODE" "$HAVSFUNC" 2>/dev/null || {
            # macOS sed syntax differs
            sed -i '' "/^import vapoursynth as vs/a\\
$PATCH_CODE" "$HAVSFUNC"
        }

        # Replace analyse_args usage
        sed -i '' 's/\*\*analyse_args)/**_fix_mv_args(analyse_args))/g' "$HAVSFUNC" 2>/dev/null || \
        sed -i 's/\*\*analyse_args)/**_fix_mv_args(analyse_args))/g' "$HAVSFUNC"

        # Replace recalculate_args usage
        sed -i '' 's/\*\*recalculate_args)/**_fix_mv_args(recalculate_args))/g' "$HAVSFUNC" 2>/dev/null || \
        sed -i 's/\*\*recalculate_args)/**_fix_mv_args(recalculate_args))/g' "$HAVSFUNC"

        rm -f "$HAVSFUNC.bak"
        PATCHES_APPLIED="mvtools API"
    fi

    # Patch 2: DFTTest API (sstring parameter removed in newer versions)
    if grep -q "sstring='0.0:4.0 0.2:9.0 1.0:15.0'" "$HAVSFUNC"; then
        echo "    Applying DFTTest API patch..."
        # Replace sstring parameter with sigma (approximate equivalent)
        sed -i '' "s/sstring='0.0:4.0 0.2:9.0 1.0:15.0'/sigma=10.0/g" "$HAVSFUNC" 2>/dev/null || \
        sed -i "s/sstring='0.0:4.0 0.2:9.0 1.0:15.0'/sigma=10.0/g" "$HAVSFUNC"
        PATCHES_APPLIED="${PATCHES_APPLIED:+$PATCHES_APPLIED, }DFTTest API"
    fi

    # Patch 3: VapourSynth YCOCG removal (no longer exists in newer VS)
    if grep -q "vs\.YCOCG" "$HAVSFUNC"; then
        echo "    Applying YCOCG compatibility patch..."
        # Remove YCOCG from color family checks (it's deprecated/removed)
        sed -i '' 's/input\.format\.color_family not in \[vs\.YUV, vs\.YCOCG\]/input.format.color_family != vs.YUV/g' "$HAVSFUNC" 2>/dev/null || \
        sed -i 's/input\.format\.color_family not in \[vs\.YUV, vs\.YCOCG\]/input.format.color_family != vs.YUV/g' "$HAVSFUNC"
        sed -i '' "s/'LUTDeCrawl: This is not an 8-10 bit YUV or YCoCg clip'/'LUTDeCrawl: This is not an 8-10 bit YUV clip'/g" "$HAVSFUNC" 2>/dev/null || \
        sed -i "s/'LUTDeCrawl: This is not an 8-10 bit YUV or YCoCg clip'/'LUTDeCrawl: This is not an 8-10 bit YUV clip'/g" "$HAVSFUNC"
        PATCHES_APPLIED="${PATCHES_APPLIED:+$PATCHES_APPLIED, }YCOCG removal"
    fi

    if [ -n "$PATCHES_APPLIED" ]; then
        echo "    havsfunc patched ($PATCHES_APPLIED)"
    else
        echo "    havsfunc already patched, skipping"
    fi
fi

# ============================================================================
# Copy Python from Homebrew (if available)
# ============================================================================
echo "[7/7] Setting up Python..."

# Try to find Python version used by VapourSynth
PYTHON_VERSION=""
for ver in 3.12 3.11 3.10 3.9; do
    if [ -d "$BREW_PREFIX/opt/python@$ver" ]; then
        PYTHON_VERSION="$ver"
        break
    fi
done

if [ -n "$PYTHON_VERSION" ]; then
    PYTHON_FRAMEWORK="$BREW_PREFIX/opt/python@$PYTHON_VERSION/Frameworks/Python.framework"
    if [ -d "$PYTHON_FRAMEWORK" ]; then
        echo "    Found Python $PYTHON_VERSION framework"
        echo "    Note: Python framework will be copied during packaging"
        echo "    Location: $PYTHON_FRAMEWORK"
    fi
else
    echo "    WARNING: Python not found in Homebrew"
    echo "    Please install: brew install python@3.11"
fi

# Cleanup
echo ""
echo "Cleaning up..."
rm -rf "$TEMP_DIR"

# Summary
echo ""
echo "=== Download Complete ==="
echo ""
echo "Dependencies installed to: $DEPS_DIR"
echo ""
echo "Contents:"
ls -la "$DEPS_DIR/"
echo ""
echo "VapourSynth plugins:"
ls -la "$DEPS_DIR/vapoursynth/plugins/" 2>/dev/null || echo "  (none found)"
echo ""
echo "Python packages:"
ls -la "$DEPS_DIR/python-packages/"
echo ""

# Check for missing dependencies
MISSING=""
[ ! -f "$DEPS_DIR/ffmpeg/ffmpeg" ] && MISSING="$MISSING ffmpeg"
[ ! -f "$DEPS_DIR/vapoursynth/vspipe" ] && MISSING="$MISSING vspipe"
[ ! -f "$DEPS_DIR/vapoursynth/plugins/libmvtools.dylib" ] && MISSING="$MISSING mvtools"
[ ! -f "$DEPS_DIR/vapoursynth/plugins/libdfttest.dylib" ] && MISSING="$MISSING dfttest"
[ ! -f "$DEPS_DIR/python-packages/havsfunc.py" ] && MISSING="$MISSING havsfunc"

# Check for FFTW (required by dfttest)
if [ ! -f "$DEPS_DIR/vapoursynth/libfftw3f.dylib" ] && [ ! -f "$DEPS_DIR/vapoursynth/libfftw3f.3.dylib" ]; then
    MISSING="$MISSING fftw"
fi

if [ -n "$MISSING" ]; then
    echo "WARNING: Missing dependencies:$MISSING"
    echo ""
    echo "Please install missing dependencies via Homebrew:"
    echo "  brew install vapoursynth vapoursynth-mvtools vapoursynth-ffms2 fftw"
    echo ""
    echo "Note: dfttest may need to be compiled from source or installed via vsrepo"
    echo ""
fi

echo "Next steps:"
echo "  1. Build the worker: cd worker && cargo build --release"
echo "  2. Build the app: cd app && flutter build macos --release"
echo "  3. Package: ./Scripts/package-macos.sh"
