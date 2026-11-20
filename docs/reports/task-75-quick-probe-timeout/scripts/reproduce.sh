#!/usr/bin/env bash
# Task #75: runs the timing scripts with a deps bundle's Python, the way
# WorkerHarness.workerEnv does on macOS/Linux.
#   reproduce.sh <deps/platform dir>
set -euo pipefail
D=$(cd "$1" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
LIB=DYLD_LIBRARY_PATH; [ "$(uname)" = Linux ] && LIB=LD_LIBRARY_PATH
export PYTHONHOME="$D/python" PYTHONPATH="$D:$D/python-packages" PYTHONNOUSERSITE=1 \
       XDG_CONFIG_HOME="$D/config" "$LIB=$D/vapoursynth:$D/python/lib:$D/lib"
PY="$D/python/bin/python3"; FF="$D/ffmpeg/ffmpeg"
"$PY" "$HERE/lut_cost.py"
"$PY" "$HERE/lut_order.py"
"$PY" "$HERE/time_cells.py" "$FF" havsfunc.LUTDeCrawl,havsfunc.LUTDeRainbow,havsfunc.FixChromaBleedingMod
"$PY" "$HERE/time_cells.py" "$FF" havsfunc.LUTDeCrawl,havsfunc.LUTDeRainbow memo
"$PY" "$HERE/time_quick.py" "$FF" 1 nomemo
"$PY" "$HERE/time_quick.py" "$FF" 1 memo
