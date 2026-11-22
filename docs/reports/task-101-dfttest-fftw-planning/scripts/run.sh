#!/bin/bash
# Run one of this report's scripts with a macOS/Linux deps bundle's Python:
#   run.sh <deps dir> <script.py> [args...]
D="$(cd "$1" && pwd)"; shift
cd "$(dirname "$0")"
PYTHONHOME="$D/python" PYTHONPATH="$D:$D/python-packages" PYTHONNOUSERSITE=1 \
XDG_CONFIG_HOME="$D/config" VAPOURBOX_FFMPEG="$D/ffmpeg/ffmpeg" VAPOURBOX_DEPS="$D" \
SCRATCH="${SCRATCH:-$(mktemp -d)}" "$D/python/bin/python3" "$@"
