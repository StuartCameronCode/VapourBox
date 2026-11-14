#!/bin/bash
# Generate seek_timebase_2997.mov: a 29.97 fps MOV whose video track time base
# is 1/11988, the timescale a user's ProRes clip had (issue #157).
#
# Why this fixture exists: with that time base (and MP4's 1/2997, and TS's
# 1/90000), an ffmpeg that seeks and writes rawvideo used to emit the first
# kept frame twice, so the preview showed frame N-1 and trimmed encodes were a
# frame late. interlaced_test.avi (1/25) cannot show it, which is how it went
# unnoticed. integration_seek_alignment_test.dart decodes it from several start
# frames and compares against a sequential decode.
#
# Content: testsrc2 (every frame differs), 320x240, 3 s = 90 frames, H.264 with
# B-frames, plus a sine AAC track so the container has audio like a real clip.
#
# Usage: ./generate_seek_timebase_test.sh [output_dir] [ffmpeg]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-$SCRIPT_DIR}"
FFMPEG="${2:-ffmpeg}"
FFPROBE="$(dirname "$FFMPEG")/ffprobe"
[ -x "$FFPROBE" ] || FFPROBE=ffprobe
OUT="$OUTPUT_DIR/seek_timebase_2997.mov"

"$FFMPEG" -y -v error \
    -f lavfi -i "testsrc2=size=320x240:rate=30000/1001:duration=3.003" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=3.003" \
    -map 0:v -map 1:a \
    -c:v libx264 -preset veryfast -crf 20 -g 30 -bf 2 -pix_fmt yuv420p \
    -c:a aac -b:a 64k \
    -video_track_timescale 11988 \
    "$OUT"

tb="$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=time_base -of csv=p=0 "$OUT")"
if [ "$tb" != "1/11988" ]; then
    echo "expected video time base 1/11988, got $tb" >&2
    exit 1
fi
frames="$("$FFPROBE" -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 "$OUT")"
echo "Wrote $OUT (time base $tb, $frames frames)"
