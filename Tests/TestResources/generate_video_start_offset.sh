#!/bin/bash
# Generate the late-video fixtures: sources whose video starts 1 s after their
# audio, as on a broadcast (DVB-T) capture.
#
# Why they exist: an input -ss counts from the container's start, which is the
# earliest stream's. When the audio starts first, "frame N" used to name a
# picture about 25 frames early in the preview, the before frame and a trim;
# MKV/MP4 untrimmed decodes padded the gap with 25 copies of the first picture
# (and MP4 lost its last second to -frames:v); and an untrimmed TS encode came
# out with the sound late by the whole gap. integration_video_start_offset_test
# decodes, previews and encodes these and checks which picture each path shows
# and that sound and picture stay in step.
#
# Content, identical in all three:
#   video  testsrc2 (every frame differs), 320x240, 25 fps, 100 frames (4 s),
#          a white frame at source frames 25 and 75
#   audio  5 s, a quiet 200 Hz tone with a 40 ms 1 kHz beep at the moments the
#          white frames are shown (2.0 s and 4.0 s on the audio's timeline)
#   the video starts 1 s after the audio (-itsoffset), so each beep lands on
#   its flash when the two are played by their timestamps.
#
#   late_video_intra.ts  H.264 all-intra + MP2 (all-intra so a TS seek lands
#                        on the frame asked for: the keyframe overshoot of
#                        MPEG-PS/TS seeks is a separate problem)
#   late_video_gop.ts    H.264, GOP 25 with B-frames + MP2: a TS that has to
#                        seek a GOP early and trim to the frame (issue #169)
#   late_video.mkv       H.264, GOP 25 with B-frames + FLAC
#   late_video.mp4       H.264, GOP 25 with B-frames + AAC (an edit list holds
#                        the gap)
#
# Usage: ./generate_video_start_offset.sh [output_dir] [ffmpeg]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-$SCRIPT_DIR}"
FFMPEG="${2:-ffmpeg}"
FFPROBE="$(dirname "$FFMPEG")/ffprobe"
[ -x "$FFPROBE" ] || FFPROBE=ffprobe

VIDEO="testsrc2=size=320x240:rate=25:duration=4,drawbox=c=white:t=fill:enable='eq(n\,25)+eq(n\,75)'"
AUDIO="aevalsrc=0.05*sin(2*PI*200*t)+0.6*sin(2*PI*1000*t)*(between(t\,2\,2.04)+between(t\,4\,4.04)):s=48000:d=5:c=mono"

make() {
    local out="$1"; shift
    "$FFMPEG" -y -v error \
        -itsoffset 1.0 -f lavfi -i "$VIDEO" \
        -f lavfi -i "$AUDIO" \
        -map 0:v -map 1:a -pix_fmt yuv420p "$@" "$OUTPUT_DIR/$out"
    local start vstart frames
    start="$("$FFPROBE" -v error -show_entries format=start_time -of csv=p=0 "$OUTPUT_DIR/$out" | head -n1)"
    vstart="$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=start_time -of csv=p=0 "$OUTPUT_DIR/$out" | head -n1)"
    frames="$("$FFPROBE" -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 "$OUTPUT_DIR/$out" | head -n1)"
    if [ "$frames" != 100 ]; then
        echo "$out: expected 100 video frames, got $frames" >&2
        exit 1
    fi
    echo "Wrote $out (container start $start, video start $vstart, $frames frames)"
}

make late_video_intra.ts -c:v libx264 -preset veryfast -crf 30 -g 1 -c:a mp2 -b:a 64k
make late_video_gop.ts -c:v libx264 -preset veryfast -crf 26 -g 25 -bf 2 -c:a mp2 -b:a 64k
make late_video.mkv -c:v libx264 -preset veryfast -crf 26 -g 25 -bf 2 -c:a flac
make late_video.mp4 -c:v libx264 -preset veryfast -crf 26 -g 25 -bf 2 -c:a aac -b:a 64k
