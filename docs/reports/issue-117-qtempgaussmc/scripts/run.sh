#!/bin/bash
# usage: run.sh WHICH PRESET [tail-lines]
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/../../../.."
S="${SCRATCH:?set SCRATCH to your scratch directory}"
deps/macos-arm64/ffmpeg/ffmpeg -v error -i Tests/TestResources/interlaced_test.avi -f rawvideo -pix_fmt yuv422p - 2>/dev/null | \
 ( /usr/bin/time -p env WHICH=$1 PRESET="$2" TPL=$PWD/worker/templates CONV=$S/conv PLUG=$S/plug PYTHONPATH=$S/jet \
   deps/macos-arm64/vapoursynth/vspipe -c y4m $HERE/q.vpy $S/"out_$1_$2.y4m" ) 2>&1 | tail -${3:-6}
