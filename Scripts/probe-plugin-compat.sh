#!/bin/bash
# Test which bundled VapourSynth plugins this machine's CPU can run (issue #92).
#
#   bash probe-plugin-compat.sh [path-to-deps-folder]
#
# Runs probe-plugin-compat.py (which must sit next to this script) with the deps
# bundle's own Python, so no system Python is needed. Writes the report to
# ~/Desktop/vapourbox-plugin-compat-report.txt.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

if [ $# -ge 1 ]; then
    DEPS="$1"
elif [ "$(uname)" = "Darwin" ]; then
    [ "$(uname -m)" = "arm64" ] && ID=macos-arm64 || ID=macos-x64
    DEPS="$HOME/Library/Application Support/VapourBox/deps/$ID"
else
    [ "$(uname -m)" = "aarch64" ] && ID=linux-arm64 || ID=linux-x64
    DEPS="${XDG_DATA_HOME:-$HOME/.local/share}/VapourBox/deps/$ID"
fi

PY="$DEPS/python/bin/python3"
if [ ! -x "$PY" ]; then
    echo "Could not find VapourBox's bundled Python at: $PY"
    echo "Open VapourBox once so it can download its components, then try again."
    exit 1
fi

exec "$PY" "$HERE/probe-plugin-compat.py" "$DEPS" "${@:2}"
