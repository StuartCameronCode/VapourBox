#!/bin/bash
# Generate a soft telecine test video for detection testing.
#
# Soft telecine means:
#   - Stored frames are progressive at ~23.976fps
#   - repeat_first_field flags in the MPEG-2 bitstream signal 3:2 pulldown
#   - A decoder displays frames at ~29.97fps by repeating fields as flagged
#   - No actual interlaced fields exist — frames are fully progressive
#   - Codec: MPEG-2 (typical for DVD soft telecine)
#   - Resolution: 720x480 (NTSC DVD)
#
# This differs from hard telecine where frames are physically interlaced.
# Detection relies on repeat_pict flags showing a 3:2 pattern (~40% ratio).
#
# Method: ffmpeg's MPEG-2 encoder doesn't support soft pulldown directly,
# so we encode progressive MPEG-2, then patch the bitstream to add
# repeat_first_field flags in a 3:2 cadence, and remux to MKV.
#
# Usage: ./generate_soft_telecine_test.sh [output_dir]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-$SCRIPT_DIR}"

TEMP_RAW="$(mktemp /tmp/soft_telecine_raw.XXXXXX.mpg)"
TEMP_PATCHED="$(mktemp /tmp/soft_telecine_patched.XXXXXX.mpg)"
SOFT_TELECINE_OUT="$OUTPUT_DIR/soft_telecine_test.mkv"

cleanup() {
    rm -f "$TEMP_RAW" "$TEMP_PATCHED"
}
trap cleanup EXIT

echo "=== Generating soft telecine test video ==="

# Step 1: Encode 5-second 23.976fps progressive MPEG-2
# Uses testsrc2 (clock, moving bars, colour patterns) with frame numbers
# overlaid — useful for verifying correct pulldown removal (no dups).
echo "[1/3] Encoding 23.976fps progressive MPEG-2..."
ffmpeg -y -hide_banner -loglevel warning \
    -f lavfi -i "testsrc2=size=720x480:rate=24000/1001:duration=5" \
    -vf "drawtext=text='SOFT TELECINE':fontsize=28:fontcolor=yellow:x=(w-text_w)/2:y=20,\
drawtext=text='Frame %{n}':fontsize=24:fontcolor=white:x=(w-text_w)/2:y=h-50,\
format=yuv420p" \
    -c:v mpeg2video -b:v 15M \
    -g 15 -bf 0 \
    "$TEMP_RAW"

# Step 2: Patch the MPEG-2 bitstream to add 3:2 pulldown flags
# Sets progressive_sequence=1 in sequence extension, and
# repeat_first_field + progressive_frame in picture coding extensions.
#
# MPEG-2 picture coding extension layout (after 00 00 01 b5):
#   byte 7, bit 7: top_field_first
#   byte 7, bit 6: frame_pred_frame_dct
#   byte 7, bit 1: repeat_first_field
#   byte 8, bit 7: progressive_frame
#
# When progressive_sequence=1, progressive_frame=1, and repeat_first_field=1,
# the decoder displays the frame for 3 field periods instead of 2.
echo "[2/3] Patching bitstream with 3:2 pulldown flags..."
python3 - "$TEMP_RAW" "$TEMP_PATCHED" << 'PYEOF'
import sys

EXTENSION_START_CODE = b'\x00\x00\x01\xb5'

def find_all(data, needle):
    positions = []
    pos = 0
    while True:
        pos = data.find(needle, pos)
        if pos == -1:
            break
        positions.append(pos)
        pos += 1
    return positions

input_path = sys.argv[1]
output_path = sys.argv[2]

with open(input_path, 'rb') as f:
    data = bytearray(f.read())

ext_positions = find_all(data, EXTENSION_START_CODE)

# 3:2 pulldown pattern: repeat on frames 0 and 2 of every 5 (40% ratio)
pattern = [1, 0, 1, 0, 0]
pic_count = 0

for pos in ext_positions:
    if pos + 8 >= len(data):
        continue
    ext_id = (data[pos + 4] >> 4) & 0xf

    if ext_id == 1:
        # Sequence extension: set progressive_sequence (byte 5, bit 3)
        data[pos + 5] |= 0x08

    elif ext_id == 8:
        repeat = pattern[pic_count % len(pattern)]

        # Set progressive_frame and frame_pred_frame_dct
        data[pos + 8] |= 0x80  # progressive_frame
        data[pos + 7] |= 0x40  # frame_pred_frame_dct

        if repeat:
            data[pos + 7] |= 0x82   # top_field_first + repeat_first_field
        else:
            data[pos + 7] &= ~0x82  # clear both

        pic_count += 1

with open(output_path, 'wb') as f:
    f.write(data)

print(f"    Patched {pic_count} frames with 3:2 pulldown pattern")
PYEOF

# Step 3: Remux to MKV (preserves the patched bitstream as-is)
echo "[3/3] Remuxing to MKV and verifying..."
ffmpeg -y -hide_banner -loglevel warning \
    -i "$TEMP_PATCHED" \
    -c copy \
    "$SOFT_TELECINE_OUT"

echo ""
echo "--- Output file info ---"
ffprobe -hide_banner \
    -show_entries stream=codec_name,width,height,r_frame_rate,avg_frame_rate,field_order \
    -show_entries format=duration,size \
    -of flat \
    "$SOFT_TELECINE_OUT" 2>/dev/null | grep -E "codec_name|width|height|r_frame_rate|avg_frame_rate|field_order|duration|size"

echo ""
echo "--- Soft telecine detection (repeat_pict flags, first 20 frames) ---"
ffprobe -hide_banner -v quiet \
    -show_entries frame=repeat_pict \
    -select_streams v:0 \
    -read_intervals "%+#20" \
    -of csv=p=0 \
    "$SOFT_TELECINE_OUT" 2>/dev/null | head -20 | tr '\n' ' '
echo ""

FILE_SIZE=$(ls -lh "$SOFT_TELECINE_OUT" | awk '{print $5}')
echo ""
echo "=== Done ==="
echo "Output: $SOFT_TELECINE_OUT ($FILE_SIZE)"
echo ""
echo "This file simulates a DVD source with soft 3:2 pulldown."
echo "Stored frames are progressive at ~23.976fps with repeat_first_field"
echo "flags in a 3:2 pattern (~40% of frames have repeat_pict > 0)."
echo "Frame numbers are overlaid to verify no duplicates after pulldown removal."
