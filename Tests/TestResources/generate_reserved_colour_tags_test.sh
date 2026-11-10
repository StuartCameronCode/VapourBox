#!/bin/bash
# Generate the two ProRes clips tagged with `reserved` colour primaries and
# transfer (docs/reports/2026-11-reserved-colour-tags).
#
# FFmpeg 9's scaler refuses to convert a frame tagged `reserved`, so before the
# fix the app's "before" frame, its thumbnails, Detect borders and Descale's
# Detect all failed on such a source, and so did the encode whenever the
# decoder converts to the pipe format.
#
# The tags come from the prores_metadata bitstream filter: its `unknown`
# constant writes code 0, which is Apple's "unknown" and ISO 23091's
# `reserved` — FFmpeg's decoder reports the latter. That is exactly what the
# user's clip carries (color_primaries=reserved, color_transfer=reserved,
# color_space=unknown). Stream copy only, so the pictures are untouched.
#
#   reserved_colour_tags.mov        ProRes 422 yuv422p10le, 15 frames of
#                                   prores422_10bit_telecine.mov; laid out like
#                                   the user's clip: pcm_s24le audio as stream
#                                   0, video as stream 1, a 1/11988 timescale.
#   reserved_colour_tags_4444a.mov  ProRes 4444 with alpha (yuva444p12le when
#                                   decoded), 320x240, 10 frames: not a pipe
#                                   format, so the ENCODE decoder converts it.
#
# Usage: ./generate_reserved_colour_tags_test.sh [output_dir]
# FFMPEG / FFPROBE override the tools (default: ffmpeg / ffprobe on PATH).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-$SCRIPT_DIR}"
FFMPEG="${FFMPEG:-ffmpeg}"
FFPROBE="${FFPROBE:-ffprobe}"
SOURCE="$SCRIPT_DIR/prores422_10bit_telecine.mov"
OUT_422="$OUTPUT_DIR/reserved_colour_tags.mov"
OUT_4444="$OUTPUT_DIR/reserved_colour_tags_4444a.mov"
RESERVED="prores_metadata=color_primaries=unknown:color_trc=unknown"

if [ ! -f "$SOURCE" ]; then
  echo "Missing $SOURCE — run ./generate_prores422_10bit_test.sh first." >&2
  exit 1
fi

"$FFMPEG" -v error -y \
  -i "$SOURCE" \
  -f lavfi -i anullsrc=r=48000:cl=stereo \
  -map 1:a -map 0:v \
  -frames:v 15 -shortest \
  -c:a pcm_s24le \
  -c:v copy -bsf:v "$RESERVED" \
  -video_track_timescale 11988 \
  "$OUT_422"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"$FFMPEG" -v error -y \
  -f lavfi -i "testsrc2=s=320x240:r=30000/1001:d=1" \
  -frames:v 10 \
  -c:v prores_ks -profile:v 4 -vendor apl0 -pix_fmt yuva444p10le \
  "$TMP/4444a.mov"
"$FFMPEG" -v error -y -i "$TMP/4444a.mov" -c:v copy -bsf:v "$RESERVED" "$OUT_4444"

# The fixtures are only worth anything if they reproduce the tags.
for f in "$OUT_422" "$OUT_4444"; do
  tags="$("$FFPROBE" -v error -select_streams v:0 \
    -show_entries stream=color_primaries,color_transfer -of csv=p=0 "$f")"
  if [ "$tags" != "reserved,reserved" ]; then
    echo "$f has tags '$tags', not 'reserved,reserved'" >&2
    exit 1
  fi
  echo "Wrote $f ($(wc -c < "$f" | tr -d ' ') bytes): $("$FFPROBE" -v error \
    -select_streams v:0 -show_entries stream=pix_fmt,color_primaries,color_transfer,color_space \
    -of compact=p=0 "$f")"
done
