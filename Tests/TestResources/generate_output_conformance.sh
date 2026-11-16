#!/bin/bash
# Generate the output conformance matrix's sources (task #49): one content,
# four source classes, so one oracle covers every case
# (app/test/support/output_matrix.dart, integration_output_conformance_test.dart).
#
# Content, identical in all four:
#   video  testsrc2 (every frame differs), 160x120, 25 fps, 100 pictures (4 s),
#          a white frame at pictures 5, 30, 55 and 80
#   audio  48 kHz mono, a quiet 200 Hz tone with a 20 ms 1 kHz click at the
#          moment each white frame is shown
#   25 fps x 48 kHz: one frame is exactly 1920 samples, so every trim lands on
#   a whole sample and the lossless checks can be exact.
#
#   conf_plain.mp4       H.264 GOP 25 with B-frames + AAC (primed, edit list);
#                        sound and picture start together
#   conf_late_video.ts   H.264 GOP 25 with B-frames + MP2 in MPEG-TS, the video
#                        1 s after the sound (a DVB-T capture)
#   conf_delayed.avi     MPEG-4 ASP with B-frames (Xvid-style: decode-order
#                        timestamps, decoder delay 1) + MP3
#   conf_reset.mpg       MPEG-2 + MP2 in MPEG-PS (DVD-style), two parts each
#                        with its own clock, joined: the clock resets at
#                        picture 51 (2.04 s: a whole number of MP2 frames, so
#                        sound and picture end the first part together)
#   conf_reset_offgrid.mpg  the same, reset at picture 50 (2.0 s: 83.3 MP2
#                        frames), where the first part's sound ends 16 ms
#                        after its picture, as a DVD cell's may
#
# Usage: ./generate_output_conformance.sh [output_dir] [ffmpeg]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-$SCRIPT_DIR}"
FFMPEG="${2:-ffmpeg}"
FFPROBE="$(dirname "$FFMPEG")/ffprobe"
[ -x "$FFPROBE" ] || FFPROBE=ffprobe

FLASHES="eq(n\,5)+eq(n\,30)+eq(n\,55)+eq(n\,80)"
VIDEO="testsrc2=size=160x120:rate=25:duration=4,drawbox=c=white:t=fill:enable='$FLASHES'"
# The clicks at 0.2, 1.2, 2.2 and 3.2 s on the picture's timeline, shifted by
# the sound's lead ($1 s).
audio() {
    local lead="$1" dur="$2" clicks="" t
    for t in 0.2 1.2 2.2 3.2; do
        local at
        at="$(echo "$t + $lead" | bc -l)"
        clicks="$clicks+between(t\,$at\,$at+0.02)"
    done
    echo "aevalsrc=0.05*sin(2*PI*200*t)+0.6*sin(2*PI*1000*t)*(${clicks#+}):s=48000:d=$dur:c=mono"
}

frames_of() {
    "$FFPROBE" -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames \
        -of csv=p=0 "$1" | head -n1
}

# Plain: both streams start at 0.
"$FFMPEG" -y -v error -f lavfi -i "$VIDEO" -f lavfi -i "$(audio 0 4)" \
    -map 0:v -map 1:a -pix_fmt yuv420p \
    -c:v libx264 -preset veryfast -crf 30 -g 25 -bf 2 -c:a aac -b:a 96k \
    "$OUTPUT_DIR/conf_plain.mp4"

# Late video: the picture 1 s after the sound.
"$FFMPEG" -y -v error -itsoffset 1.0 -f lavfi -i "$VIDEO" -f lavfi -i "$(audio 1 5)" \
    -map 0:v -map 1:a -pix_fmt yuv420p \
    -c:v libx264 -preset veryfast -crf 30 -g 25 -bf 2 -c:a mp2 -b:a 96k \
    -f mpegts "$OUTPUT_DIR/conf_late_video.ts"

# Delayed AVI: decode-order timestamps.
"$FFMPEG" -y -v error -f lavfi -i "$VIDEO" -f lavfi -i "$(audio 0 4)" \
    -map 0:v -map 1:a -pix_fmt yuv420p \
    -c:v mpeg4 -vtag XVID -bf 2 -g 25 -q:v 4 -c:a libmp3lame -b:a 96k \
    "$OUTPUT_DIR/conf_delayed.avi"

# Reset: pictures 0..at-1 and at..99 as two program streams, each from 0.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
reset_at() {
    local at="$1" out="$2" part first count
    for part in 0 1; do
        first=$((part * at)); count=$(( part == 0 ? at : 100 - at ))
        "$FFMPEG" -y -v error \
            -f lavfi -i "$VIDEO,trim=start_frame=$first:end_frame=$((first + count)),setpts=PTS-STARTPTS" \
            -f lavfi -i "$(audio 0 4),atrim=start=$(echo "$first / 25" | bc -l):duration=$(echo "$count / 25" | bc -l),asetpts=PTS-STARTPTS" \
            -map 0:v -map 1:a -pix_fmt yuv420p \
            -c:v mpeg2video -b:v 400k -g 12 -bf 2 -flags -cgop -sc_threshold 1000000000 \
            -c:a mp2 -b:a 96k -f vob "$tmp/$part.mpg"
    done
    cat "$tmp/0.mpg" "$tmp/1.mpg" > "$OUTPUT_DIR/$out"
}
reset_at 51 conf_reset.mpg
reset_at 50 conf_reset_offgrid.mpg

for f in conf_plain.mp4 conf_late_video.ts conf_delayed.avi; do
    n="$(frames_of "$OUTPUT_DIR/$f")"
    [ "$n" = 100 ] || { echo "$f: expected 100 pictures, got $n" >&2; exit 1; }
done
vstart="$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=start_time -of csv=p=0 "$OUTPUT_DIR/conf_late_video.ts" | head -n1)"
astart="$("$FFPROBE" -v error -select_streams a:0 -show_entries stream=start_time -of csv=p=0 "$OUTPUT_DIR/conf_late_video.ts" | head -n1)"
echo "conf_late_video.ts: video starts at $vstart, sound at $astart"
b="$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=has_b_frames -of csv=p=0 "$OUTPUT_DIR/conf_delayed.avi")"
[ "$b" -gt 0 ] || { echo "conf_delayed.avi: no B-frames" >&2; exit 1; }
for f in conf_reset.mpg conf_reset_offgrid.mpg; do
    seq="$("$FFMPEG" -v error -i "$OUTPUT_DIR/$f" -map 0:v -f null - -progress pipe:1 \
        | awk -F= '$1 == "frame" { f = $2 } END { print f }')"
    [ "$seq" = 100 ] || { echo "$f: expected 100 pictures in a sequential decode, got $seq" >&2; exit 1; }
done
echo "Wrote conf_plain.mp4, conf_late_video.ts, conf_delayed.avi, conf_reset.mpg, conf_reset_offgrid.mpg to $OUTPUT_DIR"
