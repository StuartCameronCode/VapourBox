#!/bin/bash
# The two clips the report needs besides the committed fixture, from the same
# NASA public-domain source (see Tests/TestResources/generate_face_test.sh):
#
#   face_clean.mkv  the fixture's crop and scale with none of its damage
#                   (the flicker reference), lossless
#   face_1080.mp4   3 s of the uncropped 1080p original (the 1080p speed run)
#
#   ./make_refs.sh <source.webm> <out dir> [ffmpeg]
set -euo pipefail
SRC="${1:?source .webm}"; OUT="${2:?output dir}"; FF="${3:-ffmpeg}"
mkdir -p "$OUT"
"$FF" -y -v error -ss 50 -t 5 -i "$SRC" -an \
  -vf "fps=30000/1001,crop=720:540:728:140,scale=640:480:flags=lanczos,format=yuv420p" \
  -c:v ffv1 "$OUT/face_clean.mkv"
"$FF" -y -v error -ss 50 -t 3 -i "$SRC" -an -vf "fps=30000/1001,format=yuv420p" \
  -c:v libx264 -crf 16 -preset fast "$OUT/face_1080.mp4"
ls -l "$OUT"
