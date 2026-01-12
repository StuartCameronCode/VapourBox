#!/bin/bash
# build-dependencies.sh
# Downloads and prepares all bundled dependencies for iDeinterlace
#
# Prerequisites:
# - Homebrew installed
# - Python 3.11+ installed
# - Xcode command line tools

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DEPS_DIR="$PROJECT_DIR/BundledDependencies"

echo "=== iDeinterlace Dependency Builder ==="
echo "Project directory: $PROJECT_DIR"
echo "Dependencies directory: $DEPS_DIR"

# Create directories
mkdir -p "$DEPS_DIR/Python.framework"
mkdir -p "$DEPS_DIR/VapourSynth"
mkdir -p "$DEPS_DIR/FFmpeg"
mkdir -p "$DEPS_DIR/Scripts"

echo ""
echo "=== Step 1: Download Python Framework ==="
echo "For bundling, we recommend using Python-Apple-support from BeeWare:"
echo "  https://github.com/beeware/Python-Apple-support"
echo ""
echo "Download the macOS Python 3.11 framework and extract to:"
echo "  $DEPS_DIR/Python.framework/"
echo ""

echo "=== Step 2: Install VapourSynth ==="
echo "Install VapourSynth into the embedded Python:"
echo ""
echo "  # Activate embedded Python"
echo "  export PYTHONHOME=$DEPS_DIR/Python.framework/Versions/3.11"
echo "  export PATH=\$PYTHONHOME/bin:\$PATH"
echo ""
echo "  # Install VapourSynth"
echo "  pip install vapoursynth"
echo ""

echo "=== Step 3: Download VapourSynth Plugins ==="
echo "Required plugins (download macOS .dylib files):"
echo "  - mvtools (motion estimation)"
echo "  - nnedi3 or znedi3 (neural network interpolation)"
echo "  - fmtconv (format conversion)"
echo "  - ffms2 or lsmash (source loading)"
echo ""
echo "Sources:"
echo "  - https://github.com/vapoursynth/vs-mvtools/releases"
echo "  - https://github.com/sekrit-twc/znedi3/releases"
echo "  - https://github.com/EleonoreMizo/fmtconv/releases"
echo "  - https://github.com/FFMS/ffms2/releases"
echo ""
echo "Place .dylib files in: $DEPS_DIR/VapourSynth/plugins/"
echo ""

echo "=== Step 4: Download FFmpeg ==="
echo "Download a static FFmpeg build for macOS:"
echo "  https://evermeet.cx/ffmpeg/"
echo ""
echo "Or build from source with required codecs."
echo "Place ffmpeg and ffprobe in: $DEPS_DIR/FFmpeg/"
echo ""

echo "=== Step 5: Download Python Scripts ==="
echo "Download havsfunc.py and dependencies:"
echo "  https://github.com/HomeOfVapourSynthEvolution/havsfunc"
echo ""
echo "Required scripts:"
echo "  - havsfunc.py (contains QTGMC)"
echo "  - mvsfunc.py"
echo "  - adjust.py (if needed)"
echo ""
echo "Place in: $DEPS_DIR/Scripts/"
echo ""

echo "=== Step 6: Copy vspipe ==="
echo "Copy vspipe from VapourSynth installation:"
echo "  cp /path/to/vspipe $DEPS_DIR/VapourSynth/"
echo ""

echo "=== Manual Steps Required ==="
echo "This script provides guidance only. You must:"
echo "1. Download and extract Python.framework"
echo "2. Install vapoursynth pip package"
echo "3. Download VS plugin .dylib files"
echo "4. Download FFmpeg binaries"
echo "5. Download Python helper scripts"
echo ""
echo "After completing these steps, run codesign-dependencies.sh"
echo ""

# Create placeholder gitkeep file
touch "$DEPS_DIR/Scripts/.gitkeep"

echo "Done. Dependencies directory structure created."
