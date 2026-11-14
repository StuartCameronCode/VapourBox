#!/bin/bash
# Run one probe script inside the deps bundle's Python.
#   SRESTORE_PROBE_DIR=/some/scratch ./run.sh <script.py> [args]
# Deps: $VAPOURBOX_DEPS, else <repo>/deps/<platform> (macOS arm64 measured).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
: "${SRESTORE_PROBE_DIR:?set SRESTORE_PROBE_DIR to a scratch directory}"
export VAPOURBOX_DEPS="${VAPOURBOX_DEPS:-$REPO/deps/macos-arm64}"
D="$VAPOURBOX_DEPS"
export PYTHONHOME="$D/python"
export PYTHONPATH="$D:$D/python-packages"
export DYLD_LIBRARY_PATH="$D/vapoursynth:$D/python/lib"
export XDG_CONFIG_HOME="$SRESTORE_PROBE_DIR/config"
mkdir -p "$XDG_CONFIG_HOME"
exec "$D/python/bin/python3" "$HERE/$1" "${@:2}"
