#!/bin/bash
# Generate the AVI seek fixtures (issue #173):
#
#   avi_ntsc_intra.avi    MPEG-4 ASP, no B-frames, 29.97 fps. Every packet has a
#                         PTS (no decoder delay), but an AVI's time base is one
#                         frame, so the seek's (N - 0.5) / fps sits exactly on a
#                         half tick: the rounding tie alone, as on HuffYUV, DV or
#                         Lagarith NTSC captures (1 start in 3 was a frame early).
#   avi_h264_bframes.avi  H.264 with B-frames (decoder delay 2) and a PCM tone,
#                         29.97 fps: decode-order timestamps only, so every seek
#                         landed 2 frames early and frames 1-3 jumped ~2 s.
#
# hard_telecine_test.avi (MPEG-2, delay 1) covers the third case.
# integration_seek_alignment_test.dart decodes all three from several start
# frames and compares against a sequential decode.
#
# Content: testsrc2 (every frame differs), 320x240, 90 frames.
#
# Usage: ./generate_avi_seek_test.sh [output_dir] [ffmpeg]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-$SCRIPT_DIR}"
FFMPEG="${2:-ffmpeg}"
FFPROBE="$(dirname "$FFMPEG")/ffprobe"
[ -x "$FFPROBE" ] || FFPROBE=ffprobe

SRC="testsrc2=size=320x240:rate=30000/1001:duration=3.003"

"$FFMPEG" -y -v error -f lavfi -i "$SRC" \
    -c:v mpeg4 -bf 0 -g 15 -q:v 3 -pix_fmt yuv420p \
    "$OUTPUT_DIR/avi_ntsc_intra.avi"

"$FFMPEG" -y -v error -f lavfi -i "$SRC" \
    -f lavfi -i "sine=frequency=440:sample_rate=32000:duration=3.003" \
    -map 0:v -map 1:a \
    -c:v libx264 -preset veryfast -crf 23 -g 30 -bf 2 -pix_fmt yuv420p \
    -c:a pcm_s16le \
    "$OUTPUT_DIR/avi_h264_bframes.avi"

check() {
    local file="$1" want_b="$2"
    local b frames
    b="$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=has_b_frames -of csv=p=0 "$file")"
    frames="$("$FFPROBE" -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 "$file")"
    if [ "$b" != "$want_b" ] || [ "$frames" != "90" ]; then
        echo "$file: expected has_b_frames=$want_b and 90 frames, got $b and $frames" >&2
        exit 1
    fi
}
check "$OUTPUT_DIR/avi_ntsc_intra.avi" 0
check "$OUTPUT_DIR/avi_h264_bframes.avi" 2
echo "Wrote avi_ntsc_intra.avi and avi_h264_bframes.avi to $OUTPUT_DIR"
