#!/bin/bash
# The encoder's subtitle mapping, measured with the bundle's FFmpeg alone
# (issue #266): how far the sound runs ahead of the picture in file order,
# and the encoder's peak memory, for today's mapping and two fixes.
#
# Usage: scripts/probe.sh [deps/<platform> dir]
# Scratch files go to $ISSUE266_SCRATCH (default: a new temporary directory).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
DEPS="${1:-$REPO/deps/macos-arm64}"
FF="$DEPS/ffmpeg/ffmpeg"
FP="$DEPS/ffmpeg/ffprobe"
W="${ISSUE266_SCRATCH:-$(mktemp -d)}"
mkdir -p "$W"
cd "$W"
"$FF" -version | head -1

printf '1\n00:00:01,000 --> 00:00:02,000\nhello\n\n2\n00:00:50,000 --> 00:00:51,000\nbye\n' > s.srt
"$FF" -v error -f lavfi -i testsrc2=s=320x240:r=25:d=60 -f lavfi -i "sine=f=440:d=60:sample_rate=48000" \
    -c:v libx264 -preset ultrafast -c:a aac -y src_nosub.mkv
"$FF" -v error -i src_nosub.mkv -i s.srt -map 0 -map 1 -c copy -y src_sub.mkv
# 7.1 PCM s32 96 kHz: a sound heavy enough for buffering to show in memory.
"$FF" -v error -i src_sub.mkv -f lavfi -i "sine=f=440:d=60:sample_rate=96000" \
    -filter_complex "[1:a]pan=7.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0|c6=c0|c7=c0[a]" \
    -map 0:v -map "[a]" -map 0:s -c:v copy -c:s copy -c:a pcm_s32le -y src_fat.mkv

# Bytes per second of 320x240 4:2:0 at 50 fps: a pipe at twice real time.
RATE=5760000

# encode <name> <source> <throttle: yes|no> <x264 preset> <inputs and maps...>
encode() {
    local name=$1 src=$2 throttle=$3 preset=$4; shift 4
    local rss
    if [ "$throttle" = yes ]; then
        rss=$( { "$FF" -v error -i "$src" -map 0:v -f yuv4mpegpipe - | python3 "$HERE/throttle.py" $RATE |
            /usr/bin/time -l "$FF" -v error -f yuv4mpegpipe -i - "$@" -c:a copy -c:s copy \
            -c:v libx264 -preset "$preset" -y "$name.mkv"; } 2>&1 | awk '/maximum resident/ {print $1}')
    else
        rss=$( { "$FF" -v error -i "$src" -map 0:v -f yuv4mpegpipe - |
            /usr/bin/time -l "$FF" -v error -f yuv4mpegpipe -i - "$@" -c:a copy -c:s copy \
            -c:v libx264 -preset "$preset" -y "$name.mkv"; } 2>&1 | awk '/maximum resident/ {print $1}')
    fi
    printf '%-28s lead %6s s   peak RSS %4d MB\n' "$name" "$(python3 "$HERE/lead.py" "$FP" "$name.mkv")" $((rss / 1048576))
}

encode no_subtitles      src_nosub.mkv yes ultrafast -i src_nosub.mkv -map 0:v -map '1:a?' -map '1:s?'
encode subtitles_today   src_sub.mkv   yes ultrafast -i src_sub.mkv   -map 0:v -map '1:a?' -map '1:s?'
encode subtitles_today_unthrottled src_sub.mkv no medium -i src_sub.mkv -map 0:v -map '1:a?' -map '1:s?'
encode pcm71_today       src_fat.mkv   yes ultrafast -i src_fat.mkv   -map 0:v -map '1:a?' -map '1:s?'
encode pcm71_own_input   src_fat.mkv   yes ultrafast -i src_fat.mkv -i src_fat.mkv -map 0:v -map '1:a?' -map '2:s?'
encode pcm71_mid0        src_fat.mkv   yes ultrafast -i src_fat.mkv   -map 0:v -map '1:a?' -map '1:s?' -max_interleave_delta 0
