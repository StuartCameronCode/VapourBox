#!/bin/bash
# usage: eval.sh LABEL WHICH PRESET KW [NNPATCH]
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/../../../.."
S="${SCRATCH:?set SCRATCH to your scratch directory}"
FF=deps/macos-arm64/ffmpeg/ffmpeg
line="$1"
for seg in 0 1400; do
  out=$S/gt/out_$1_$seg.y4m
  t0=$(python3 -c 'import time;print(time.time())')
  env WHICH=$2 PRESET="$3" KW="$4" NNPATCH=$5 DEPTH=$6 W=320 H=240 NF=120 TPL=$PWD/worker/templates CONV=$S/conv PLUG=$S/plug PYTHONPATH=$S/jet \
    deps/macos-arm64/vapoursynth/vspipe -c y4m $HERE/q2.vpy $out < $S/gt/int$seg.yuv 2>$S/gt/err_$1_$seg.txt || { echo "$1 FAILED"; tail -3 $S/gt/err_$1_$seg.txt; exit 1; }
  t1=$(python3 -c 'import time;print(time.time())')
  fps=$(python3 -c "print(round(240/($t1-$t0),1))")
  m=$($FF -v info -i $out -f rawvideo -pix_fmt yuv422p -s 320x240 -framerate 50 -i $S/gt/ref$seg.yuv \
      -lavfi "[0:v]extractplanes=y[a];[1:v]extractplanes=y[b];[a][b]psnr;[0:v]extractplanes=y[c];[1:v]extractplanes=y[d];[c][d]ssim" -f null - 2>&1 | grep -oE "(average|All):[0-9.]+" | tr '\n' ' ')
  line="$line | seg$seg ${fps}fps $m"
done
echo "$line"
