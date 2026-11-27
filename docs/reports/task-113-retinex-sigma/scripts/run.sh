#!/bin/bash
# Run one of this report's Python scripts with a macOS/Linux deps bundle's
# Python and VapourSynth:
#   run.sh <deps dir> <script.py> [args...]
# SCRATCH (default: a new temporary directory) holds the decoded frames.
D="$(cd "$1" && pwd)"; shift
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
PYTHONHOME="$D/python" PYTHONPATH="$D:$D/python-packages" PYTHONNOUSERSITE=1 \
XDG_CONFIG_HOME="$D/config" DYLD_LIBRARY_PATH="$D/lib" LD_LIBRARY_PATH="$D/lib" \
SCRATCH="${SCRATCH:-$(mktemp -d)}" "$D/python/bin/python3" "$@"
