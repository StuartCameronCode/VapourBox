#!/bin/sh
# Reproduce every number in the report.
#
#   WORK=/scratch/dir  FFMPEG=<deps>/ffmpeg/ffmpeg  [DEEP_FILTER=<deep-filter 0.5.6>]  ./run.sh
#
# Needs Python 3 with NumPy. FFMPEG defaults to the macOS arm64 deps bundle
# beside the repo; DEEP_FILTER to the add-on as the app installs it, if present.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
: "${WORK:?set WORK to a scratch directory}"
: "${FFMPEG:=$REPO/deps/macos-arm64/ffmpeg/ffmpeg}"
export WORK FFMPEG
if [ -z "$DEEP_FILTER" ]; then
  for f in "$REPO"/addons/deepfilternet/deep-filter-0.5.6-*; do
    [ -x "$f" ] && DEEP_FILTER="$f"
  done
fi
[ -n "$DEEP_FILTER" ] && export DEEP_FILTER
PY="${PYTHON:-python3}"
cd "$HERE"
"$PY" delay_probe.py
"$PY" start_offset_probe.py
"$PY" tempo_denoise_probe.py
"$PY" quality_probe.py
