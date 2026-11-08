#!/bin/bash
# Run a script (colorize_run.py) inside the deps bundle's Python with VapourSynth
# importable, as the vspipe wrapper sets it up, plus the repo's templates and
# the ai-runtime add-on on PYTHONPATH and the bundle's ffmpeg on PATH.
#
#   DEPS=<deps/macos-arm64>  ADDONS=<addons dir holding ai-runtime>
#   VAPOURBOX_ADDON_STAGING=<converted .onnx files>
#   ./run.sh colorize_run.py --clip ... [args]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
: "${DEPS:?set DEPS to the deps bundle (deps/macos-arm64)}"
: "${ADDONS:?set ADDONS to the add-ons directory holding ai-runtime}"
: "${VAPOURBOX_ADDON_STAGING:?set VAPOURBOX_ADDON_STAGING to the converted models}"
export PATH="$DEPS/ffmpeg:$DEPS/python/bin:$PATH"
export PYTHONHOME="$DEPS/python"
export PYTHONPATH="$DEPS:$DEPS/python-packages:$REPO/worker/templates:$ADDONS/ai-runtime/site-packages"
export DYLD_LIBRARY_PATH="$DEPS/vapoursynth:$DEPS/python/lib"
export LD_LIBRARY_PATH="$DEPS/vapoursynth:$DEPS/python/lib"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$DEPS/config}"
script="$1"; shift
exec "$DEPS/python/bin/python3" "$HERE/$script" "$@"
