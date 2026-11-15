#!/bin/bash
# Generate avi_aac_overshoot.mkv: a mono soundtrack that makes ffmpeg's AAC
# encoder write packets over the 768 bytes per channel avienc declares as an
# AAC stream's block size in AVI (task #41).
#
# Why it exists: a reader times each AAC chunk of an AVI as
# ceil(size / nBlockAlign) packets (ffmpeg, VLC, DirectShow), so every packet
# over 768 bytes made everything after it one packet (21.3 ms) later. The
# worker now raises nBlockAlign to the largest chunk (worker/src/avi_header.rs).
# integration_video_start_offset_test encodes this to AVI at High (192 kbps)
# and Very High (256 kbps), converted and copied, asserts that packets over
# 768 bytes were written (else the test would prove nothing) and that every
# beep still lands on its white frame by the file's timestamps.
# The late_video fixtures don't do this: none overshoots on the app's own
# paths. See docs/reports/issue-41-aac-avi-block-align.
#
# Content:
#   video  testsrc2 (every frame differs), 320x240, 25 fps, 200 frames (8 s),
#          a white frame at frames 25, 75, 125 and 175
#   audio  8 s, mono 48 kHz FLAC, starting with the video: a quiet 200 Hz
#          tone, white-noise bursts (peak 0.12, 50 ms every 0.11 s: these are
#          what overshoot, at any level), silent within 0.1 s of each beep,
#          and a 40 ms 1 kHz beep (0.6) at each white frame (1, 3, 5 and 7 s).
#          Nothing but the beeps exceeds 0.3, the level the test's beep
#          detector listens for, after AAC too: decoded, the bursts peak at
#          0.23 (at 0.2 they reached 0.40 and read as beeps).
#
# Usage: ./generate_avi_aac_overshoot.sh [output_dir] [ffmpeg]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-$SCRIPT_DIR}"
FFMPEG="${2:-ffmpeg}"
FFPROBE="$(dirname "$FFMPEG")/ffprobe"
[ -x "$FFPROBE" ] || FFPROBE=ffprobe

VIDEO="testsrc2=size=320x240:rate=25:duration=8,drawbox=c=white:t=fill:enable='eq(n\,25)+eq(n\,75)+eq(n\,125)+eq(n\,175)'"
BEEPS="0.6*sin(2*PI*1000*t)*(between(t\,1\,1.04)+between(t\,3\,3.04)+between(t\,5\,5.04)+between(t\,7\,7.04))"
OUT="$OUTPUT_DIR/avi_aac_overshoot.mkv"

"$FFMPEG" -y -v error \
    -f lavfi -i "$VIDEO" \
    -f lavfi -i "aevalsrc=0.04*sin(2*PI*200*t)+$BEEPS:s=48000:d=8:c=mono" \
    -f lavfi -i "anoisesrc=r=48000:a=0.12:c=white:seed=1:d=8" \
    -filter_complex "[2]volume='lt(mod(t,0.11),0.05)*(1-between(mod(t,2),0.9,1.1))':eval=frame[n];[1][n]amix=inputs=2:normalize=0[a]" \
    -map 0:v -map "[a]" -pix_fmt yuv420p \
    -c:v libx264 -preset veryfast -crf 26 -g 25 -bf 2 -c:a flac "$OUT"

frames="$("$FFPROBE" -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 "$OUT" | head -n1)"
if [ "$frames" != 200 ]; then
    echo "avi_aac_overshoot.mkv: expected 200 video frames, got $frames" >&2
    exit 1
fi
echo "Wrote avi_aac_overshoot.mkv ($frames frames)"
