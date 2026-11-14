#!/bin/bash
# Generate the Unblend (SRestore) fixtures: progressive footage converted to
# another frame rate by BLENDING, then interlaced, the way a standards
# converter does it. The ground truth is small_clip.mp4 itself, so a test can
# check which original frame each restored frame is.
#
#   blended_film_50i.mkv   small_clip frames 1350..1493 (144 frames) taken as
#                          23.976p film, repeated 2:3 to 59.94 (as telecine
#                          does), blended to 50p by linear interpolation
#                          between the two nearest frames, interlaced to 25i TFF.
#                          Deinterlaced at double rate and unblended to
#                          23.976, it should give back the 144 film frames.
#   blended_pal_5994i.mkv  the same frames 1350..1474 (125) taken as 25p PAL,
#                          blended to 59.94p and interlaced to 29.97i TFF, at
#                          10-bit 4:2:2. Unblended to 25 it should give them back.
#
# Lossy (x264, CRF 10) on purpose: real blended material is never lossless,
# and the tests compare against the source with a tolerance calibrated by the
# same chain without the blending (docs/reports/2026-11-srestore).
#
# Usage: ./generate_blended_test.sh [output_dir] [ffmpeg]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-$SCRIPT_DIR}"
FFMPEG="${2:-ffmpeg}"
SRC="$SCRIPT_DIR/small_clip.mp4"
FIRST=1350

# framerate=...:interp_start=0:interp_end=255 blends at every position;
# scene=100 stops it treating a fast pan as a cut (it would copy, not blend).
BLEND="interp_start=0:interp_end=255:scene=100"

"$FFMPEG" -y -v error -i "$SRC" \
    -vf "select='between(n\,$FIRST\,$((FIRST + 143)))',setpts=N/(24000/1001)/TB,fps=60000/1001,framerate=fps=50:$BLEND,tinterlace=mode=interleave_top,setfield=tff" \
    -an -c:v libx264 -preset slow -crf 10 -pix_fmt yuv420p \
    -flags +ildct+ilme -x264-params tff=1 \
    "$OUTPUT_DIR/blended_film_50i.mkv"

"$FFMPEG" -y -v error -i "$SRC" \
    -vf "select='between(n\,$FIRST\,$((FIRST + 124)))',setpts=N/25/TB,format=yuv422p10le,framerate=fps=60000/1001:$BLEND,tinterlace=mode=interleave_top,setfield=tff" \
    -an -c:v libx264 -preset slow -crf 10 -pix_fmt yuv422p10le \
    -flags +ildct+ilme -x264-params tff=1 \
    "$OUTPUT_DIR/blended_pal_5994i.mkv"

FFPROBE="$(dirname "$FFMPEG")/ffprobe"
[ -x "$FFPROBE" ] || FFPROBE=ffprobe
for f in blended_film_50i.mkv blended_pal_5994i.mkv; do
    info="$("$FFPROBE" -v error -select_streams v:0 -count_frames \
        -show_entries stream=r_frame_rate,nb_read_frames,pix_fmt,field_order -of csv=p=0 "$OUTPUT_DIR/$f")"
    echo "Wrote $OUTPUT_DIR/$f ($info)"
done
