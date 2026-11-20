#!/usr/bin/env bash
# Run a Python script with a deps bundle's Python and VapourSynth (macOS/Linux),
# the environment WorkerHarness.workerEnv gives the worker.
#   bundle_python.sh <deps/<platform> dir> <script.py> [args...]
set -euo pipefail
DEPS="$(cd "$1" && pwd)"; shift
export PYTHONHOME="$DEPS/python"
export PYTHONPATH="$DEPS:$DEPS/python-packages"
export PYTHONNOUSERSITE=1
export XDG_CONFIG_HOME="$DEPS/config"
exec "$DEPS/python/bin/python3" "$@"
