#!/bin/bash
# Reproduces every number in ../index.html.
#
#   [DEPS=deps/macos-arm64] ./reproduce.sh
#
# The frame is decoded from Tests/TestResources/small_clip.mp4 into $SCRATCH
# (default: a new temporary directory).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
D="$(cd "${DEPS:-$REPO/deps/macos-arm64}" && pwd)"
SCRATCH="${SCRATCH:-$(mktemp -d)}"
"$D/ffmpeg/ffmpeg" -v error -y -ss 5 -i "$REPO/Tests/TestResources/small_clip.mp4" \
  -frames:v 3 "$SCRATCH/f%d.png"
run() {
  PYTHONHOME="$D/python" PYTHONPATH="$D:$D/python-packages" PYTHONNOUSERSITE=1 \
    XDG_CONFIG_HOME="$D/config" DYLD_LIBRARY_PATH="$D/lib" \
    "$D/python/bin/python3" "$@" 2>&1 | grep -v '^Warning: Plugin'
}
echo "== Convolution's own edge rule"
run "$HERE/convolution_edges.py"
echo "== gaussian_blur against TCanny(mode=-1)"
run "$HERE/compare.py" "$REPO/worker/templates" "$SCRATCH/f2.png"
echo "== speed, 1080p, 200 frames"
run "$HERE/speed.py" "$REPO/worker/templates"
