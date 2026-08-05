#!/bin/bash
# Generate a 10-bit ProRes 422 telecined test clip.
#
# This reproduces the source from issue: IVTC (vivtc.VFM) failing on >8-bit
# input. ProRes 422 decodes to yuv422p10le (10-bit), which VFM rejects unless
# the pipeline runs field matching on an 8-bit copy and emits full-depth pixels
# via VFM's clip2 parameter.
#
# Properties (matching the reported source):
#   - Codec: Apple ProRes 422 (Standard, apcn)
#   - Pixel format: yuv422p10le (10-bit)
#   - Field order: top field first (interlaced / telecined)
#   - Resolution: 720x480 (NTSC), 29.97fps, ~1s (30 frames = 6 3:2 cycles)
#
# Drop the resulting .mov into the app and run Deinterlace > IVTC (or a preview)
# to exercise the high-bit-depth path.
#
# Usage: ./generate_prores422_10bit_test.sh [output_dir]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-$SCRIPT_DIR}"
SOURCE="$SCRIPT_DIR/hard_telecine_test.avi"
OUTPUT="$OUTPUT_DIR/prores422_10bit_telecine.mov"

if [ ! -f "$SOURCE" ]; then
  echo "Missing $SOURCE — run ./generate_telecine_test.sh first." >&2
  exit 1
fi

ffmpeg -y -i "$SOURCE" \
  -frames:v 30 \
  -c:v prores_ks -profile:v 2 -vendor apl0 -pix_fmt yuv422p10le \
  -vf setfield=tff \
  -flags +ildct+ilme \
  "$OUTPUT"

echo "Wrote $OUTPUT"
ffmpeg -i "$OUTPUT" 2>&1 | grep -E "Stream|Duration" || true
