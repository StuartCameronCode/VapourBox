#!/bin/bash
# The report's figures, from the PNGs bench.sh wrote.
#
#   WORK=<bench.sh's scratch dir>  ./make_figures.sh <report img dir>   (ffmpeg on PATH)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
: "${WORK:?}"
IMG="${1:?img dir}"
R="$WORK/runs"
FIX="$REPO/Tests/TestResources/colorize_test.mp4"
mkdir -p "$IMG"
src() { ffmpeg -v error -y -i "$FIX" -vf "select=eq(n\,$1)" -frames:v 1 "$WORK/src_$1.png"; }
src 20
src 110

# 1: source | DDColor | DeOldify Video (defaults: radius 2), frames 20 and 110.
for n in 20 110; do
  ffmpeg -v error -y -i "$WORK/src_$n.png" -i "$R/ddcolor_r2_$n.png" -i "$R/deoldify_r2_$n.png" \
    -filter_complex "[0][1][2]hstack=3,scale=1440:-2" "$WORK/row_$n.png"
done
ffmpeg -v error -y -i "$WORK/row_20.png" -i "$WORK/row_110.png" -filter_complex vstack \
  -compression_level 9 "$IMG/01-models.png"

# 2: DDColor per frame (radius 0) vs smoothed (radius 2), frame 110.
ffmpeg -v error -y -i "$R/ddcolor_r0_110.png" -i "$R/ddcolor_r2_110.png" \
  -filter_complex "[0][1]hstack=2,scale=1280:-2" -compression_level 9 "$IMG/02-smoothing.png"

# 3: strength 0.5 | 1 | 1.5 (DDColor), frame 110.
ffmpeg -v error -y -i "$R/ddcolor_s05_2.png" -i "$R/ddcolor_r2_110.png" -i "$R/ddcolor_s15_2.png" \
  -filter_complex "[0][1][2]hstack=3,scale=1440:-2" -compression_level 9 "$IMG/03-strength.png"

# 4: a colour source: the source | DDColor | DeOldify Video (face fixture, frame 60).
ffmpeg -v error -y -i "$REPO/Tests/TestResources/face_restore_test.mp4" -vf "select=eq(n\,60)" \
  -frames:v 1 "$WORK/colour_src.png"
ffmpeg -v error -y -i "$WORK/colour_src.png" -i "$R/colour_ddcolor_0.png" -i "$R/colour_deoldify_0.png" \
  -filter_complex "[0][1][2]hstack=3,scale=1440:-2" -compression_level 9 "$IMG/04-colour-source.png"
ls -l "$IMG"
