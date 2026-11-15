#!/bin/sh
# Reproduces every number in index.html. Needs VAPOURBOX_DEPS_DIR (a deps
# bundle; ffmpeg/ffprobe are taken from it) and a debug worker build:
#   (cd worker && cargo build)
# BEFORE_WORKER may name a worker built from main before task #30 (a7ba1ac)
# for the "before" table.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../.." && pwd)
out=${OUT:-"$repo/Tests/TestOutput/avi-late-video"}
mkdir -p "$out"
if [ -n "${BEFORE_WORKER:-}" ]; then
  echo "## before ($BEFORE_WORKER)"
  python3 "$here/worker_avi_late.py" "$BEFORE_WORKER" "$out/before"
fi
echo "## after"
python3 "$here/worker_avi_late.py" "$repo/worker/target/debug/vapourbox-worker" "$out/after"
echo "## candidates (ffmpeg only)"
RES="$repo/Tests/TestResources" OUT="$out/candidates" sh -c 'mkdir -p "$OUT" && python3 "$0" late_video_intra.ts late_video.mp4' "$here/candidates.py"
