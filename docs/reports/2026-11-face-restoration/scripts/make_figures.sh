#!/bin/bash
# The report's images, from bench.sh's PNGs: face crops (200x200 from the
# 640x480 frame, scaled 2x nearest-neighbour) side by side, and one full frame.
#
#   WORK=<bench.sh's scratch dir>  CLEAN=<face_clean.mkv>  ./make_figures.sh [ffmpeg]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
FF="${1:-ffmpeg}"
: "${WORK:?}" "${CLEAN:?}"
IMG="$HERE/../img"
R="$WORK/runs"
FIX="$REPO/Tests/TestResources/face_restore_test.mp4"
mkdir -p "$IMG" "$WORK/fig"
CROP="crop=200:200:210:100,scale=400:400:flags=neighbor"
frame() { "$FF" -v error -y -i "$1" -vf "select=eq(n\,$2),$CROP" -frames:v 1 "$3"; }
crop() { "$FF" -v error -y -i "$1" -vf "$CROP" -frames:v 1 "$2"; }

frame "$FIX" 75 "$WORK/fig/in.png"
frame "$CLEAN" 75 "$WORK/fig/clean.png"
for t in rf_r1_75 rf_r1_s08_75 gfpgan_r1_75 codeformer_r1_75; do crop "$R/$t.png" "$WORK/fig/$t.png"; done
# 1: input | clean source | RestoreFormer++ | GFPGAN | CodeFormer (strength 1, smoothing on)
"$FF" -v error -y -i "$WORK/fig/in.png" -i "$WORK/fig/clean.png" -i "$WORK/fig/rf_r1_75.png" \
  -i "$WORK/fig/gfpgan_r1_75.png" -i "$WORK/fig/codeformer_r1_75.png" -filter_complex hstack=5 "$IMG/01-models.png"
# 2: input | RestoreFormer++ strength 1 | strength 0.8 (the default)
"$FF" -v error -y -i "$WORK/fig/in.png" -i "$WORK/fig/rf_r1_75.png" -i "$WORK/fig/rf_r1_s08_75.png" \
  -filter_complex hstack=3 "$IMG/02-strength.png"
# 3: the whole frame, input above restored (default strength)
"$FF" -v error -y -i "$FIX" -i "$R/rf_r1_s08_75.png" -filter_complex \
  "[0:v]select=eq(n\,75),scale=640:480[a];[a][1:v]vstack=2,scale=480:-1" -frames:v 1 "$IMG/03-frame.png"
ls -l "$IMG"
