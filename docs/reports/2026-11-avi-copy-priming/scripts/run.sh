#!/bin/sh
# Reproduces every number in index.html. Needs VAPOURBOX_DEPS_DIR (a deps
# bundle; ffmpeg/ffprobe are taken from it) and a debug worker build:
#   (cd worker && cargo build)
# BEFORE_WORKER may name a worker built from main before task #43 (929383f)
# for the "before" rows.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../.." && pwd)
out=${OUT:-"$repo/Tests/TestOutput/avi-copy-priming"}
fx="$out/fixtures"
mkdir -p "$out"
echo "## fixtures"
"$here/fixtures.sh" "$VAPOURBOX_DEPS_DIR/ffmpeg" "$fx"
cp "$repo/Tests/TestResources/small_clip.mp4" "$fx/"
echo "## candidates (ffmpeg only)"
FX="$fx" OUT="$out/candidates" python3 "$here/candidates.py" master48000.mkv aac.mkv aac.mp4 aac44.mkv aac_stereo.mkv \
  mp3.mkv mp3.mp4 mp3_44.mkv ac3.mkv mp2.mkv small_clip.mp4
FX="$fx" OUT="$out/candidates" ONLY=AG python3 "$here/candidates.py" mp2_60.mkv ac3_60.mkv
echo "## sound against the source's sound, and the head (A current, B disabled, E the cut)"
for f in aac.mkv aac.mp4 mp3.mkv ac3.mkv mp2.mkv small_clip.mp4; do
  echo "# $f"
  python3 "$here/xcorr.py" "$fx/$f" "$out/candidates/${f}_A.avi" "$out/candidates/${f}_B.avi" "$out/candidates/${f}_E.avi"
done
if [ -n "${BEFORE_WORKER:-}" ]; then
  echo "## before ($BEFORE_WORKER)"
  python3 "$here/worker_copy_avi.py" "$BEFORE_WORKER" "$out/before" "$fx"
fi
echo "## after"
python3 "$here/worker_copy_avi.py" "$repo/worker/target/debug/vapourbox-worker" "$out/after" "$fx"
