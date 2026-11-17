#!/bin/bash
# Generate edit_list_bframes.mp4: an MP4 whose edit list discards pre-roll,
# with holes in its picture timestamps before the end (task #54).
#
# Why this fixture exists: an MP4/MOV edit list that starts after the media's
# first sample keeps the samples from the keyframe before it so the decoder
# can reach the first shown picture, and the mov demuxer marks them discard
# (ffprobe `packet=flags` "D"). They are never output, but `nb_frames` (the
# sample table) counts them, so a count from `nb_frames` asked the decoder for
# frames it never delivers (small_clip.mp4: 3154 stored, 3151 decoded). This
# one is harder: the stream copy's `-t` also drops the last B pictures, so the
# kept pictures' timestamps have holes, which the source grid fills by
# repeating the slot before (issue #174). Counting the packets not discarded
# gives 125, as does `-count_frames`; the grid decode, and so the right count,
# is the last kept picture's slot + 1: 128.
#
# Content: testsrc2 (every frame differs), 320x240 at 30000/1001, H.264 with
# 3 B-frames and a 48-frame GOP, 12 s, cut by stream copy at 2.3 s for 4.1 s.
# Committed: x264 versions differ, and a regenerated file may differ in its
# numbers (the script checks the shape, not the counts).
#
# Usage: ./generate_edit_list_test.sh [output_dir] [ffmpeg]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-$SCRIPT_DIR}"
FFMPEG="${2:-ffmpeg}"
FFPROBE="$(dirname "$FFMPEG")/ffprobe"
[ -x "$FFPROBE" ] || FFPROBE=ffprobe
OUT="$OUTPUT_DIR/edit_list_bframes.mp4"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

"$FFMPEG" -y -v error \
    -f lavfi -i "testsrc2=size=320x240:rate=30000/1001" -t 12 \
    -c:v libx264 -preset veryfast -crf 20 -bf 3 -g 48 -pix_fmt yuv420p \
    "$TMP/src.mp4"
"$FFMPEG" -y -v error -ss 2.3 -t 4.1 -i "$TMP/src.mp4" -c copy "$OUT"

packets="$("$FFPROBE" -v error -select_streams v:0 -show_entries packet=pts_time,flags -of csv=p=0 "$OUT")"
head_discards="$(echo "$packets" | head -64 | grep -c D || true)"
kept="$(echo "$packets" | grep -vc D)"
stored="$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=nb_frames -of csv=p=0 "$OUT")"
last="$(echo "$packets" | grep -v D | cut -d, -f1 | sort -g | tail -1)"
slots="$(python3 -c "print(round($last * 30000 / 1001) + 1)")"

if [ "$head_discards" -eq 0 ]; then
    echo "expected discarded packets at the head (an edit list's pre-roll)" >&2
    exit 1
fi
if [ "$slots" -le "$kept" ]; then
    echo "expected holes in the kept pictures' timestamps ($kept kept, $slots slots)" >&2
    exit 1
fi
echo "Wrote $OUT ($stored stored, $head_discards discarded at the head, $kept kept, $slots slots)"
