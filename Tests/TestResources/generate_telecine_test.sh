#!/bin/bash
# Generate a telecined (3:2 pulldown) test video for IVTC testing.
#
# This creates a video that simulates a typical NTSC DVD source:
#   - Original content: 23.976fps progressive (film)
#   - After telecine: 29.97fps interlaced with 3:2 pulldown pattern
#   - Codec: MPEG-2 (standard for DVD)
#   - Resolution: 720x480 (NTSC DVD)
#
# The resulting file can be used to test IVTC (inverse telecine) which
# should recover the original 23.976fps progressive frames.
#
# Usage: ./generate_telecine_test.sh [output_dir]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-$SCRIPT_DIR}"

# Intermediate progressive source (will be deleted)
PROGRESSIVE_SRC="$OUTPUT_DIR/telecine_progressive_src.y4m"
# Final telecined output
TELECINE_OUT="$OUTPUT_DIR/telecine_test.avi"

echo "=== Generating telecine test video ==="

# Step 1: Generate a 3-second 23.976fps progressive source
# Uses testsrc2 which has moving elements (good for verifying frame recovery)
echo "[1/3] Generating 23.976fps progressive source..."
ffmpeg -y -hide_banner -loglevel warning \
    -f lavfi -i "testsrc2=size=720x480:rate=24000/1001:duration=3,format=yuv420p" \
    "$PROGRESSIVE_SRC"

# Step 2: Apply telecine (3:2 pulldown) to create 29.97fps interlaced output
# The 'telecine' filter applies the classic NTSC film-to-video pulldown pattern.
# Encode as MPEG-2 with top-field-first to match real DVD sources.
echo "[2/3] Applying 3:2 pulldown telecine → MPEG-2 29.97i..."
ffmpeg -y -hide_banner -loglevel warning \
    -i "$PROGRESSIVE_SRC" \
    -vf "telecine=pattern=23,setfield=tff" \
    -c:v mpeg2video -b:v 8M \
    -flags +ilme+ildct \
    -top 1 \
    -g 15 -bf 2 \
    "$TELECINE_OUT"

# Clean up intermediate file
rm -f "$PROGRESSIVE_SRC"

echo "[3/3] Verifying output..."
echo ""
echo "--- Output file info ---"
ffprobe -hide_banner \
    -show_entries stream=codec_name,width,height,r_frame_rate,field_order,nb_frames \
    -show_entries format=duration,size \
    -of flat \
    "$TELECINE_OUT" 2>/dev/null | grep -E "codec_name|width|height|r_frame_rate|field_order|nb_frames|duration|size"

echo ""
echo "--- Telecine detection (repeat_pict flags) ---"
ffprobe -hide_banner -v quiet \
    -show_entries frame=repeat_pict \
    -select_streams v:0 \
    -read_intervals "%+#20" \
    -of csv=p=0 \
    "$TELECINE_OUT" 2>/dev/null | head -20 | tr '\n' ' '
echo ""

FILE_SIZE=$(ls -lh "$TELECINE_OUT" | awk '{print $5}')
echo ""
echo "=== Done ==="
echo "Output: $TELECINE_OUT ($FILE_SIZE)"
echo ""
echo "This file simulates a DVD source with 3:2 pulldown."
echo "IVTC should recover 23.976fps progressive frames from 29.97fps interlaced input."
