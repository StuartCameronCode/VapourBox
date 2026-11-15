#!/bin/bash
# Reproduces every number and image in ../index.html.
#
#   SCRATCH=/some/scratch/dir [DEPS=deps/macos-arm64] ./reproduce.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
S="${SCRATCH:?set SCRATCH to your scratch directory}"
D="$(cd "${DEPS:-$REPO/deps/macos-arm64}" && pwd)"
FF="$D/ffmpeg/ffmpeg"
SRC="$REPO/Tests/TestResources/interlaced_test.avi"
mkdir -p "$S"
q() { "$FF" -hide_banner -loglevel error -y "$@"; }
py() {
  PYTHONHOME="$D/python" PYTHONPATH="$D:$D/python-packages:$HERE" PYTHONNOUSERSITE=1 \
    XDG_CONFIG_HOME="$D/config" "$D/python/bin/python3" "$@"
}

# Three dark vertical scratches on a real 720x576 interlaced capture.
SCR='drawbox=x=150:y=0:w=2:h=ih:color=black@0.4:t=fill,drawbox=x=361:y=0:w=1:h=ih:color=black@0.5:t=fill,drawbox=x=560:y=40:w=3:h=400:color=black@0.35:t=fill'
for f in yuv422p yuv420p; do
  q -i "$SRC" -frames:v 24 -f rawvideo -pix_fmt $f "$S/gt_$f.yuv"
  q -i "$SRC" -frames:v 24 -vf "$SCR" -f rawvideo -pix_fmt $f "$S/sc_$f.yuv"
done

echo "== 1. failures";  py "$HERE/sweep.py"
echo; echo "== 2. quality"
mkdir -p "$S/img"
py "$HERE/quality.py" "$S/gt_yuv422p.yuv" "$S/sc_yuv422p.yuv" "$S/gt_yuv420p.yuv" "$S/sc_yuv420p.yuv" "$S/img"
for g in "$S"/img/*.gray; do
  q -f rawvideo -pix_fmt gray -s 160x160 -i "$g" -vf scale=480:480:flags=neighbor "$HERE/../img/$(basename "$g" .gray).png"
done
echo; echo "== 3. carrier vs native"; py "$HERE/exact.py" "$S/sc_yuv420p.yuv"
