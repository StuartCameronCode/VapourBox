#!/usr/bin/env bash
# img/01-field-chroma.png: a 48x24 crop of the interlaced red/blue-field
# fixture after a 4:2:0 AV1 encode, enlarged 8x nearest-neighbour.
# Left: ffmpeg's own -pix_fmt conversion (swscale). Right: field-aware
# (separatefields -> 4:2:0 -> weave), as the worker's script does with zimg.
# Usage: DEPS=<deps/macos-arm64> SCRATCH=<dir> ./make_images.sh
# (run measure.py first with the same --scratch: it writes the encodes.)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FF="$DEPS/ffmpeg/ffmpeg"
: "${SCRATCH:?set SCRATCH to the --scratch given to measure.py}"
mkdir -p "$HERE/../img"
export SVT_LOG=1
SRC="$SCRATCH/field_chroma_422.mkv"
"$FF" -v error -y -i "$SRC" -pix_fmt yuv420p -c:v libsvtav1 -crf 10 -preset 8 "$SCRATCH/img_sws.mkv"
"$FF" -v error -y -i "$SRC" -vf separatefields,format=yuv420p,weave=first_field=top \
  -pix_fmt yuv420p -c:v libsvtav1 -crf 10 -preset 8 "$SCRATCH/img_field.mkv"
"$FF" -v error -y -i "$SCRATCH/img_sws.mkv" -i "$SCRATCH/img_field.mkv" -filter_complex \
  "[0:v]select=eq(n\,2),crop=48:24:336:276,scale=384:192:flags=neighbor[a];\
   [1:v]select=eq(n\,2),crop=48:24:336:276,scale=384:192:flags=neighbor[b];\
   [a]pad=392:192:0:0:white[ap];[ap][b]hstack" \
  -frames:v 1 "$HERE/../img/01-field-chroma.png"
