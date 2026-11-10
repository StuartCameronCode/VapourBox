#!/bin/bash
# Run one of this report's Python scripts with the deps bundle's own Python and
# VapourSynth (macOS / Linux layout). DEPS overrides the bundle directory.
#
#   scripts/run_vs.sh scripts/gamut.py
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
D="${DEPS:-$ROOT/deps/macos-arm64}"
export PYTHONHOME="$D/python"
export PYTHONPATH="$D:$D/python-packages"
export DYLD_LIBRARY_PATH="$D/vapoursynth:$D/python/lib"
export LD_LIBRARY_PATH="$D/vapoursynth:$D/python/lib"
export XDG_CONFIG_HOME="$D/config"
export FFMPEG="$D/ffmpeg/ffmpeg"
export REPO="$ROOT"
exec "$D/python/bin/python" "$@"
