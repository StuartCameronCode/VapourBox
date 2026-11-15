#!/bin/bash
# Generate the primed-sound fixtures: sources whose sound and picture start
# together, the sound encoded by ffmpeg, so its first packet holds the
# encoder's start-up (priming) at a negative timestamp.
#
# Why they exist: AVI cannot store a negative timestamp. An untrimmed
# Passthrough of such a source into AVI made ffmpeg shift every stream by the
# priming, so avienc wrote a null frame at the head (101 stored frames for
# 100) and the player played the priming as sound: the sound came out 18.6 ms
# (AAC) / 16.9 ms (MP3) early against the picture. The worker now cuts the
# copy at the packet nearest the first picture (task #43,
# audio_restoration::sound_cut_applies). integration_video_start_offset_test
# copies these into AVI and checks the stored frames and the sync.
# See docs/reports/2026-11-avi-copy-priming.
#
# Content, identical in both (as the late-video fixtures, with no gap):
#   video  testsrc2 (every frame differs), 320x240, 25 fps, 100 frames (4 s),
#          a white frame at frames 25 and 75
#   audio  4 s from 0, mono 48 kHz: a quiet 200 Hz tone with a 40 ms 1 kHz
#          beep at each white frame (1.0 s and 3.0 s)
#
#   primed_aac.mkv  H.264, GOP 25 with B-frames + AAC 96k (priming 1024
#                   samples: the first packet at -0.021 s)
#   primed_mp3.mp4  H.264, GOP 25 with B-frames + MP3 (libmp3lame) 128k
#                   (priming 1105 samples: the first packet at -0.023 s)
#
# AAC at 96k: mono AAC at 192k and more can write a packet over AVI's
# declared block size, a separate fault (task #41).
#
# Usage: ./generate_primed_sound_test.sh [output_dir] [ffmpeg]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-$SCRIPT_DIR}"
FFMPEG="${2:-ffmpeg}"
FFPROBE="$(dirname "$FFMPEG")/ffprobe"
[ -x "$FFPROBE" ] || FFPROBE=ffprobe

VIDEO="testsrc2=size=320x240:rate=25:duration=4,drawbox=c=white:t=fill:enable='eq(n\,25)+eq(n\,75)'"
AUDIO="aevalsrc=0.05*sin(2*PI*200*t)+0.6*sin(2*PI*1000*t)*(between(t\,1\,1.04)+between(t\,3\,3.04)):s=48000:d=4:c=mono"

make() {
    local out="$1"; shift
    "$FFMPEG" -y -v error \
        -f lavfi -i "$VIDEO" \
        -f lavfi -i "$AUDIO" \
        -map 0:v -map 1:a -pix_fmt yuv420p \
        -c:v libx264 -preset veryfast -crf 26 -g 25 -bf 2 "$@" "$OUTPUT_DIR/$out"
    local frames first
    frames="$("$FFPROBE" -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 "$OUTPUT_DIR/$out" | head -n1)"
    if [ "$frames" != 100 ]; then
        echo "$out: expected 100 video frames, got $frames" >&2
        exit 1
    fi
    first="$("$FFPROBE" -v error -select_streams a:0 -read_intervals %+#1 -show_entries packet=pts_time -of csv=p=0 "$OUTPUT_DIR/$out" | head -n1 | cut -d, -f1)"
    case "$first" in
        -*) ;;
        *) echo "$out: the first audio packet is at $first, not before 0: this ffmpeg did not prime it" >&2; exit 1 ;;
    esac
    echo "Wrote $out ($frames frames, first audio packet at $first s)"
}

make primed_aac.mkv -c:a aac -b:a 96k
make primed_mp3.mp4 -c:a libmp3lame -b:a 128k
