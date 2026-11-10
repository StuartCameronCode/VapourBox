#!/bin/bash
# Runs one of this report's Python probes under a deps bundle's own Python and
# VapourSynth (macOS/Linux layout), with the environment the worker gives vspipe.
#
#   SCRATCH=/path/to/scratch [DEPS=/path/to/deps/<platform>] ./run.sh nr_compare.py
#
# DEPS defaults to the repo's deps/macos-arm64. The probes in this report need a
# bundle with vszip >= 24.0.0 and SangNom (deps 1.16.0).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
D="${DEPS:-$REPO/deps/macos-arm64}"
: "${SCRATCH:?set SCRATCH to your scratch directory}"
export PYTHONHOME="$D/python"
export PYTHONPATH="$HERE:$D:$D/python-packages"
export PYTHONNOUSERSITE=1
export XDG_CONFIG_HOME="$D/config"
export PATH="$D/python/bin:$D/vapoursynth:$D/ffmpeg:$PATH"
export DYLD_LIBRARY_PATH="$D/vapoursynth:$D/python/lib"
export LD_LIBRARY_PATH="$D/vapoursynth:$D/python/lib:$D/lib"
export REPO
exec python3 "$HERE/$1" "${@:2}"
