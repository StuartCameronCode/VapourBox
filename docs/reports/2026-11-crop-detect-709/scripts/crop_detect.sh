#!/bin/bash
# Detection accuracy and speed for --detect-crop.
#
# 1. Builds the worker (release, for the timings) and runs the heavy test
#    app/test/integration_crop_detect_test.dart, which builds the fixtures
#    (real VHS picture on a canvas with known borders) into
#    Tests/TestOutput/crop_detect/ and asserts every edge within 2 lines.
# 2. Times the release worker on each fixture, on the two real files, and on
#    a 1080p pillarbox fixture made here in $SCRATCH.
#
# Needs: deps/macos-arm64 (or DEPS=...), Flutter, Rust. Every number in the
# report's detection table is printed by this script.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
S="${SCRATCH:?set SCRATCH to your scratch directory}"
export DEPS="${DEPS:-$ROOT/deps/macos-arm64}"
FF="$DEPS/ffmpeg/ffmpeg"
mkdir -p "$S"

(cd "$ROOT/worker" && cargo build --release -q && cargo build -q)
(cd "$ROOT/app" && VAPOURBOX_DEPS_DIR="$DEPS" flutter test test/integration_crop_detect_test.dart)

export WORKER="$ROOT/worker/target/release/vapourbox-worker"
OUT="$ROOT/Tests/TestOutput/crop_detect"
echo "== release worker =="
for f in vhs letterbox subtitles fades; do
  python3 "$HERE/detect.py" "$OUT/$f.mkv" progressive
done
python3 "$HERE/detect.py" "$OUT/vhs_interlaced.mkv" tff
python3 "$HERE/detect.py" "$ROOT/Tests/TestResources/pal-dvbt-fieldcoded-25i.ts" tff
python3 "$HERE/detect.py" "$ROOT/Tests/TestResources/interlaced_test.avi" tff

# 1080p: the VHS picture as 4:3 inside HD, 240-px pillarbox bars.
"$FF" -v error -y -i "$ROOT/Tests/TestResources/interlaced_test.avi" \
  -vf "crop=664:536:28:12,scale=1440:1080,pad=1920:1080:240:0:black" \
  -frames:v 60 -c:v ffv1 -pix_fmt yuv420p "$S/pillarbox_1080.mkv"
python3 "$HERE/detect.py" "$S/pillarbox_1080.mkv" progressive
