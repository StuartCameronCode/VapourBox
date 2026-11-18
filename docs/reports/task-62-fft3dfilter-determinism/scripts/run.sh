#!/bin/bash
# Run one of this report's scripts with a deps bundle's Python and environment:
#   run.sh <deps dir> <script.py> [args...]
# SCRATCH (environment, default a temp dir) holds the decoded fixture.
D="$(cd "$1" && pwd)"; shift
cd "$(dirname "$0")"
PYTHONHOME="$D/python" PYTHONPATH="$D:$D/python-packages" PYTHONNOUSERSITE=1 \
XDG_CONFIG_HOME="$D/config" VAPOURBOX_FFMPEG="$D/ffmpeg/ffmpeg" \
SCRATCH="${SCRATCH:-$(mktemp -d)}" "$D/python/bin/python3" "$@"
