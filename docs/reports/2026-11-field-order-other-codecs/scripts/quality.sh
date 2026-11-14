#!/bin/bash
# x264 on a still-interlaced picture: coded as progressive frames (what every
# H.264 encode of one did before this change) vs coded interlaced (MBAFF,
# -flags +ildct -x264-params tff=1|bff=1, what it does now). Reproduces Q1-Q2
# in ../index.html.
#
#   SCRATCH=/some/scratch/dir ./quality.sh      # then: python3 summarize.py $SCRATCH/quality.csv
#
# Fixtures, each piped as the worker pipes it (a Y4M whose header says Ip):
#   vhs   Tests/TestResources/interlaced_test.avi, 720x576 25i VHS, TFF (idet 75/75), 79 frames
#   dvbt  Tests/TestResources/pal-dvbt-fieldcoded-25i.ts, 720x576 25i broadcast, TFF (idet 126/126), 125 frames
#   bff   vhs with its first line dropped and a black line added at the bottom:
#         the same pictures with the field order swapped (idet: BFF 75/75)
# All as yuv420p (H.264's usual delivery format). Quality is measured per
# field: both the encode and the source are split with separatefields, so a
# progressive-coded and an interlaced-coded file are judged on the same pictures.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
S="${SCRATCH:?set SCRATCH to your scratch directory}"
DEPS="${DEPS:-$REPO/deps/macos-arm64}"
FF="$DEPS/ffmpeg/ffmpeg"
mkdir -p "$S"; cd "$S"
T="$REPO/Tests/TestResources"

"$FF" -v error -y -i "$T/interlaced_test.avi" -pix_fmt yuv420p -f yuv4mpegpipe vhs.y4m
"$FF" -v error -y -i "$T/pal-dvbt-fieldcoded-25i.ts" -an -pix_fmt yuv420p -f yuv4mpegpipe dvbt.y4m
"$FF" -v error -y -i "$T/interlaced_test.avi" -vf "crop=720:574:0:1,pad=720:576:0:0" \
  -pix_fmt yuv420p -f yuv4mpegpipe bff.y4m

now() { python3 -c 'import time; print(time.time())'; }

# measure SRC ORDER FILE -> "psnr_y ssim_all"
measure() {
  local src="$1" order="$2" f="$3"
  local log
  log=$("$FF" -hide_banner -i "$f" -f yuv4mpegpipe -i "$src" -lavfi \
    "[0:v]setfield=$order,separatefields,split[a0][a1];[1:v]setfield=$order,separatefields,split[b0][b1];[a0][b0]psnr;[a1][b1]ssim" \
    -f null - 2>&1)
  local p s
  p=$(echo "$log" | grep -o 'PSNR y:[0-9.]*' | cut -d: -f2)
  s=$(echo "$log" | grep -o 'SSIM .*All:[0-9.]*' | grep -o 'All:[0-9.]*' | cut -d: -f2)
  echo "$p $s"
}

size() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1"; }

echo "fixture,mode,rate_control,setting,bytes,kbps,psnr_y,ssim,seconds" > quality.csv
for fx in vhs dvbt bff; do
  if [ $fx = bff ]; then top=0; order=bff; x264p=bff=1; else top=1; order=tff; x264p=tff=1; fi
  frames=$("$FF" -v error -f yuv4mpegpipe -i $fx.y4m -map 0:v -c copy -f null - -stats 2>&1 | grep -o 'frame= *[0-9]*' | tail -1 | grep -o '[0-9]*' || true)
  [ -n "$frames" ] || frames=$(python3 -c "import sys; print(open('$fx.y4m','rb').read().count(b'FRAME'))")
  for mode in progressive interlaced; do
    if [ $mode = interlaced ]; then IL=(-flags +ildct -x264-params "$x264p"); else IL=(); fi
    for crf in 14 18 22 26; do
      out="$fx.$mode.crf$crf.mkv"
      t0=$(now)
      "$FF" -v error -y -top $top -f yuv4mpegpipe -i $fx.y4m ${IL[@]+"${IL[@]}"} \
        -c:v libx264 -preset medium -crf $crf "$out"
      t1=$(now)
      read -r p s < <(measure $fx.y4m $order "$out")
      b=$(size "$out")
      echo "$fx,$mode,crf,$crf,$b,$(python3 -c "print(round($b*8/($frames/25)/1000))"),$p,$s,$(python3 -c "print(round($t1-$t0,2))")" >> quality.csv
    done
    for kbps in 2000 4000 8000; do
      out="$fx.$mode.${kbps}k.mkv"
      t0=$(now)
      for pass in 1 2; do
        "$FF" -v error -y -top $top -f yuv4mpegpipe -i $fx.y4m ${IL[@]+"${IL[@]}"} \
          -c:v libx264 -preset medium -b:v ${kbps}k -pass $pass -passlogfile "$fx.$mode.$kbps" \
          $([ $pass = 1 ] && echo "-f null /dev/null" || echo "$out")
      done
      t1=$(now)
      read -r p s < <(measure $fx.y4m $order "$out")
      b=$(size "$out")
      echo "$fx,$mode,2pass,$kbps,$b,$(python3 -c "print(round($b*8/($frames/25)/1000))"),$p,$s,$(python3 -c "print(round($t1-$t0,2))")" >> quality.csv
    done
  done
done
cat quality.csv

echo
echo "== Q3: encode time, one thread, CRF 18, median of 3 (vhs)"
for mode in progressive interlaced; do
  if [ $mode = interlaced ]; then IL=(-flags +ildct -x264-params tff=1); else IL=(); fi
  ts=()
  for i in 1 2 3; do
    t0=$(now)
    "$FF" -v error -y -top 1 -f yuv4mpegpipe -i vhs.y4m ${IL[@]+"${IL[@]}"} \
      -c:v libx264 -preset medium -crf 18 -threads 1 t.mkv
    t1=$(now)
    ts+=("$(python3 -c "print($t1-$t0)")")
  done
  echo "$mode: $(python3 -c "import sys; v=sorted(map(float, sys.argv[1:])); print(f'{v[1]:.2f} s')" "${ts[@]}")"
done
