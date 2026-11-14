#!/bin/bash
# Generate the MPEG-PS/TS seek fixtures (issue #169).
#
# Why they exist: MPEG program and transport streams have no keyframe index,
# so ffmpeg seeks them by a timestamp search that lands on a non-key packet
# inside the GOP holding the frame asked for, and decoding starts at the NEXT
# keyframe: the preview, the before frame, a trim's in-point and the
# detectors' samples all came out up to a GOP late (and showed nothing past
# the last keyframe). integration_seek_alignment_test seeks into these and
# checks every picture against a sequential decode of the same file.
#
# Content: testsrc2 (every frame differs), 25 fps, 150 frames (6 s).
#
#   seek_dvd_pal.mpg       MPEG-2 program stream (the DVD/VOB muxer), 352x288,
#                          12-frame OPEN GOPs with 2 B pictures, MP2 audio:
#                          the shape of a DVD rip or a DVD import
#   seek_gop_late_video.ts H.264 in MPEG-TS, 25-frame open GOPs with 2 B
#                          pictures, MP2 audio starting 1 s before the video
#                          (as on a broadcast capture), so the seek has the
#                          video start offset (#168) to add as well
#
# Usage: ./generate_mpeg_seek_test.sh [output_dir] [ffmpeg]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-$SCRIPT_DIR}"
FFMPEG="${2:-ffmpeg}"
FFPROBE="$(dirname "$FFMPEG")/ffprobe"
[ -x "$FFPROBE" ] || FFPROBE=ffprobe

AUDIO="sine=frequency=440:sample_rate=48000:duration=7"

check() {
    local out="$1" gop="$2"
    local frames keys
    frames="$("$FFPROBE" -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 "$OUTPUT_DIR/$out" | head -n1 | cut -d, -f1)"
    if [ "$frames" != 150 ]; then
        echo "$out: expected 150 video frames, got $frames" >&2
        exit 1
    fi
    # Keyframes must be whole GOPs (gop / 25 s) apart, after the first: an
    # open-GOP stream's first GOP has no leading B pictures, so it is shorter.
    # A program stream leaves some packets without a PTS (keyframes too, as
    # on a DVD); those are skipped, so a gap may span two GOPs.
    keys="$("$FFPROBE" -v error -select_streams v:0 -show_entries packet=pts_time,flags -of csv=p=0 "$OUTPUT_DIR/$out" \
        | awk -F, -v g="$gop" '$2 ~ /^K/ { n++ } $2 ~ /^K/ && $1 != "N/A" {
                                   r = ($1 - last) / (g / 25); k = int(r + 0.5)
                                   if (timed >= 2 && (k < 1 || r - k > 0.01 || k - r > 0.01)) bad = 1
                                   last = $1; timed++ }
                               END { print (bad || timed < 3 ? "bad" : n) }')"
    if [ "$keys" = bad ]; then
        echo "$out: keyframes are not $gop frames apart" >&2
        exit 1
    fi
    echo "Wrote $out ($frames frames, $keys keyframes, GOP $gop)"
}

"$FFMPEG" -y -v error \
    -f lavfi -i "testsrc2=size=352x288:rate=25:duration=6" -f lavfi -i "$AUDIO" \
    -map 0:v -map 1:a -shortest \
    -c:v mpeg2video -b:v 600k -maxrate 1200k -bufsize 1835k -g 12 -bf 2 -flags -cgop \
    -sc_threshold 1000000000 -pix_fmt yuv420p \
    -c:a mp2 -b:a 96k -f vob "$OUTPUT_DIR/seek_dvd_pal.mpg"
check seek_dvd_pal.mpg 12

"$FFMPEG" -y -v error \
    -itsoffset 1.0 -f lavfi -i "testsrc2=size=320x240:rate=25:duration=6" \
    -f lavfi -i "$AUDIO" \
    -map 0:v -map 1:a \
    -c:v libx264 -preset veryfast -crf 28 -g 25 -keyint_min 25 -sc_threshold 0 \
    -bf 2 -x264-params open_gop=1 -pix_fmt yuv420p \
    -c:a mp2 -b:a 64k -f mpegts "$OUTPUT_DIR/seek_gop_late_video.ts"
check seek_gop_late_video.ts 25
