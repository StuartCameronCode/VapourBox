#!/bin/bash
# Decode three luma frames of Tests/TestResources/small_clip.mp4 (at 3, 8 and
# 14 s) as raw 720x540 GRAY8 into $SCRATCH: f3.gray, f8.gray, f14.gray.
#   SCRATCH=<dir> make_frames.sh <deps dir>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
: "${SCRATCH:?set SCRATCH to a scratch directory}"
FFMPEG="$(cd "$1" && pwd)/ffmpeg/ffmpeg"
mkdir -p "$SCRATCH"
for t in 3 8 14; do
    "$FFMPEG" -v error -y -ss "$t" -i "$REPO/Tests/TestResources/small_clip.mp4" -frames:v 1 \
        -vf scale=720:-2,format=gray -f rawvideo "$SCRATCH/f$t.gray"
done
ls -l "$SCRATCH"/f*.gray
