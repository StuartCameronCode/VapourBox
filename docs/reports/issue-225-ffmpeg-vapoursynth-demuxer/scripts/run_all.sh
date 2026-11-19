#!/bin/bash
# Reproduces every number in the report on macOS.
#   WORK=<scratch dir> DEPS=<deps/macos-arm64> run_all.sh [reps]
# Needs Homebrew x264 (for the FFmpeg build) and a populated deps bundle.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
: "${WORK:?set WORK to a scratch directory}"
DEPS="${DEPS:-$REPO/deps/macos-arm64}"
REPS="${1:-3}"
WORK="$WORK" "$HERE/build_ffmpeg.sh"
FF="$WORK/ffvs/bin/ffmpeg"
"$HERE/gen_sources.sh" "$DEPS/ffmpeg/ffmpeg" "$WORK/media"
mkdir -p "$WORK/vpy" && python3 "$HERE/make_vpy.py" "$REPO/worker/templates" "$WORK/vpy"
"$HERE/bench.sh" "$DEPS" "$FF" "$WORK/vpy" "$WORK/media" "$REPS" "$WORK/results.csv"
python3 "$HERE/summarise.py" "$WORK/results.csv"
# Identity check: QTGMC SD through both arms, frame by frame.
"$HERE/identity.sh" "$DEPS" "$FF" "$WORK/vpy/qtgmc_sd.vpy" "$WORK/media/sd.mkv"
# Which VSScript API versions the bundle's R78 accepts.
cc -o "$WORK/vsscript_api_probe" "$HERE/vsscript_api_probe.c"
( export PYTHONHOME="$DEPS/python" PYTHONPATH="$DEPS:$DEPS/python-packages" XDG_CONFIG_HOME="$DEPS/config" \
    DYLD_LIBRARY_PATH="$DEPS/vapoursynth:$DEPS/python/lib"
  "$WORK/vsscript_api_probe" "$DEPS/vapoursynth/libvsscript.dylib" )
