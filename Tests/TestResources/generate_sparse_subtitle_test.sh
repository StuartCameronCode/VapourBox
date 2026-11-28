#!/bin/bash
# Generate sparse_subs.mkv: a source with two subtitle cues 34 s apart.
#
# Why it exists: the encode used to take a source's subtitles from the same
# input as its sound. Between cues the subtitle stream is the one FFmpeg's
# scheduler holds everything else back for, so the source's sound ran ahead
# of the picture vspipe was still making, and once the muxer's queue spanned
# 10 s it wrote the sound out ahead of it: up to ~38 s of sound before the
# matching picture, which a player with a bounded read-ahead dropped
# (issue #266). The subtitles now come from an input of their own.
# integration_subtitle_interleave_test encodes this into MKV and MP4 and
# checks how far the sound runs ahead of the picture in the file.
# See docs/reports/issue-266-subtitle-interleave.
#
# Content:
#   video     testsrc2, 160x120, 25 fps, 40 s, H.264 (GOP 50)
#   audio     40 s mono 48 kHz 440 Hz tone, AAC 64k
#   subtitle  SRT, two cues: 1.0-2.0 s "first", 35.0-36.0 s "second"
#
# Usage: ./generate_sparse_subtitle_test.sh [output_dir] [ffmpeg]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-$SCRIPT_DIR}"
FFMPEG="${2:-ffmpeg}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

printf '1\n00:00:01,000 --> 00:00:02,000\nfirst\n\n2\n00:00:35,000 --> 00:00:36,000\nsecond\n' > "$TMP/cues.srt"

"$FFMPEG" -v error -y \
    -f lavfi -i "testsrc2=size=160x120:rate=25:duration=40" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=40" \
    -i "$TMP/cues.srt" \
    -map 0:v -map 1:a -map 2:s \
    -c:v libx264 -preset veryfast -crf 30 -g 50 -pix_fmt yuv420p \
    -c:a aac -b:a 64k -ac 1 \
    -c:s srt \
    -metadata:s:s:0 language=eng \
    "$OUTPUT_DIR/sparse_subs.mkv"

echo "Wrote $OUTPUT_DIR/sparse_subs.mkv"
