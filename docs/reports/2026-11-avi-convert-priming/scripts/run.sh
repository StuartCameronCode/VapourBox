#!/bin/sh
# Reproduces every number in index.html. Needs VAPOURBOX_DEPS_DIR (a deps
# bundle; ffmpeg/ffprobe are taken from it) and a debug worker build:
#   (cd worker && cargo build)
# BEFORE_WORKER may name a worker built from main before task #38 (7094d2b)
# for the "before" table. KBPS sets the audio bitrate (default 192, the
# app's default quality).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../.." && pwd)
out=${OUT:-"$repo/Tests/TestOutput/avi-convert-priming"}
kbps=${KBPS:-192}
mkdir -p "$out"
echo "## priming per encoder"
python3 "$here/priming.py"
if [ -n "${BEFORE_WORKER:-}" ]; then
  echo "## before ($BEFORE_WORKER)"
  python3 "$here/worker_convert_avi.py" "$BEFORE_WORKER" "$out/before" "$kbps"
fi
echo "## after"
python3 "$here/worker_convert_avi.py" "$repo/worker/target/debug/vapourbox-worker" "$out/after" "$kbps"
echo "## candidates (ffmpeg only)"
RES="$repo/Tests/TestResources" OUT="$out/candidates" python3 "$here/candidates.py" late_video_intra.ts late_video.mp4
