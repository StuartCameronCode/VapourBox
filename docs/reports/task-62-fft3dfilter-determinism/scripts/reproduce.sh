#!/bin/bash
# Re-run every measurement in this report (macOS arm64; ~3 minutes).
#
#   reproduce.sh <deps dir>
#
# <deps dir> is a deps/macos-arm64 bundle as released up to 1.17 (unpatched
# FFT3DFilter). SCRATCH (default a temp dir) holds the decoded fixture and the
# two plugin builds. bundle_with_script_build.txt, cross_process_script_build.txt
# and access_order_script_build.txt need a copy of the bundle whose
# vapoursynth/plugins/libfft3dfilter.dylib is the one download-deps-macos.sh
# builds; pass it as PATCHED_DEPS to include them.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEPS="$(cd "$1" && pwd)"
export SCRATCH="${SCRATCH:-$(mktemp -d)}"
DATA="$HERE/../data"; IMG="$HERE/../img"
mkdir -p "$DATA" "$IMG"
B="$SCRATCH/builds"
"$HERE/build.sh" "$DEPS" "$B"
run() { "$HERE/run.sh" "$DEPS" "$@"; }

run td2.py repeat 6 full,fft3d_spat,fft3d_bt1,fft3d_post,mvdegrain,dfttest > "$DATA/bisect.txt"
{ run fft.py variants; run fft.py blank; } > "$DATA/variants.txt"
run where.py blank > "$DATA/where_blank.txt"
run det.py 8 > "$DATA/bundle_1.16.0.txt"
{ echo "# 1.16.0 bundle"; run edge.py; } > "$DATA/edge.txt"
run fixed.py "$B" repeat > "$DATA/builds.txt"
run td2fixed.py "$B" > "$DATA/td2_qtgmc_builds.txt"
for bits in 8 16; do
    for i in 1 2 3 4 5 6 7; do run fixed.py "$B" hash $bits; done > "$DATA/cross_process_${bits}bit.txt"
done
run wrap.py "$B" > "$DATA/wrapper.txt"
run change.py "$B" > "$DATA/change.txt"
run figures.py "$B" "$IMG" > "$DATA/figures.txt"

if [ -n "${PATCHED_DEPS:-}" ]; then
    P="$(cd "$PATCHED_DEPS" && pwd)"
    "$HERE/run.sh" "$P" det.py 8 > "$DATA/bundle_with_script_build.txt"
    for m in 1 0; do for sz in 640x480 720x480 352x288; do
        echo "measure=$m $sz"
        for i in 1 2 3 4 5; do "$HERE/run.sh" "$P" xproc.py "${sz%x*}" "${sz#*x}" $m | tail -1; done | sort | uniq -c
    done; done > "$DATA/cross_process_script_build.txt"
    "$HERE/run.sh" "$P" order.py 8 > "$DATA/access_order_script_build.txt"
    { echo "# bundle with the script build"; "$HERE/run.sh" "$P" edge.py; } >> "$DATA/edge.txt"
fi
echo "done: $DATA"
