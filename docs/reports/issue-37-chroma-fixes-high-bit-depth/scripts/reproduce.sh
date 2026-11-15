#!/bin/bash
# Reproduces every number and image in ../index.html.
#
#   SCRATCH=/some/scratch/dir [DEPS=deps/macos-arm64] ./reproduce.sh
#
# Needs akarin (the fixtures use its X/Y/N operands), so not the macos-x64 bundle.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
S="${SCRATCH:?set SCRATCH to your scratch directory}"
D="$(cd "${DEPS:-$REPO/deps/macos-arm64}" && pwd)"
FF="$D/ffmpeg/ffmpeg"
mkdir -p "$S/img"
q() { "$FF" -hide_banner -loglevel error -y "$@"; }
py() {
  PYTHONHOME="$D/python" PYTHONPATH="$D:$D/python-packages:$HERE" PYTHONNOUSERSITE=1 \
    XDG_CONFIG_HOME="$D/config" "$D/python/bin/python3" "$@"
}

# The real interlaced capture, 12 frames, as 8-bit 4:2:2. common.py promotes it
# to 16-bit with genuine low bits and injects the crawl and rainbow.
q -i "$REPO/Tests/TestResources/interlaced_test.avi" -frames:v 12 -f rawvideo -pix_fmt yuv422p "$S/cap_yuv422p.yuv"

py "$HERE/precision.py" "$S/cap_yuv422p.yuv" "$S/img" | tee "$S/precision.txt"
for g in "$S"/img/*.gray; do
  q -f rawvideo -pix_fmt gray -s 160x120 -i "$g" -vf scale=480:360:flags=neighbor "$HERE/../img/$(basename "$g" .gray).png"
done
