#!/bin/bash
# Reproduces every number in the issue #148 report.
#
#   VAPOURBOX_DEPS_DIR=<deps/macos-arm64> ISSUE148_SCRATCH=<dir> ./run.sh
#
# Decodes the fixture into $ISSUE148_SCRATCH (raw video, not committed), then
# runs each probe with the bundled Python/VapourSynth. The probes exec the
# repo's own {{#FRAME_RATE}} block from pipeline_template.vpy, so they measure
# the code as it is, not a copy of it.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
: "${VAPOURBOX_DEPS_DIR:?set to a deps/<platform> directory}"
: "${ISSUE148_SCRATCH:?set to a scratch directory}"
mkdir -p "$ISSUE148_SCRATCH"
D="$VAPOURBOX_DEPS_DIR"
CLIP="$REPO/Tests/TestResources/small_clip.mp4"
"$D/ffmpeg/ffmpeg" -v error -y -i "$CLIP" -frames:v 40 -f rawvideo -pix_fmt yuv420p "$ISSUE148_SCRATCH/small.yuv"
"$D/ffmpeg/ffmpeg" -v error -y -ss 30 -i "$CLIP" -frames:v 40 -f rawvideo -pix_fmt yuv420p "$ISSUE148_SCRATCH/small30.yuv"

export TEMPLATE="$REPO/worker/templates/pipeline_template.vpy" DEPS="$D"
export PYTHONHOME="$D/python" PYTHONPATH="$HERE:$D:$D/python-packages"
export VAPOURSYNTH_PLUGIN_PATH="$D/vapoursynth/plugins"
export DYLD_LIBRARY_PATH="$D/vapoursynth:$D/python/lib" LD_LIBRARY_PATH="$D/vapoursynth:$D/python/lib"
export XDG_CONFIG_HOME="$D/config"
PY="$D/python/bin/python3"
cd "$ISSUE148_SCRATCH"
for probe in range depth matrix stress; do
  echo "== $probe"
  "$PY" "$HERE/$probe.py" 2>&1 | grep -E '^(source|smdegrain|lsfmod|[0-9]+-bit|8bit|10bit|pan|cuts)'
done
"$PY" "$HERE/images.py" >/dev/null 2>&1
echo "images: $ISSUE148_SCRATCH/*.ppm"
