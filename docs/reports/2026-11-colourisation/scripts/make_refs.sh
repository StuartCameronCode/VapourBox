#!/bin/bash
# The 1080p clip for the speed table: the same seconds of "Diary of a
# Sergeant" (1945, public domain; see Tests/TestResources/generate_colorize_test.sh)
# as the committed SD fixture, at the source's own 1920x1080 (pillarboxed 4:3),
# chroma made neutral. Also a colour clip (the face fixture) for the
# already-colour check.
#
#   ./make_refs.sh <Diary_of_a_Sergeant_(1945).webm> <out dir>   (ffmpeg on PATH)
set -euo pipefail
SRC="${1:?source webm}" OUT="${2:?output directory}"
mkdir -p "$OUT"
ffmpeg -y -v error -ss 156 -t 1 -i "$SRC" -an -vf "format=gray,format=yuv420p" \
  -c:v libx264 -preset slow -crf 18 -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  "$OUT/colorize_hd.mp4"
ls -l "$OUT"
