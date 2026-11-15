#!/bin/sh
# Reproduce every number in ../index.html (F6's Windows half: see its Reproduce).
#
#   WORK=/scratch/dir ./run.sh
#
# Needs Python 3 with NumPy, a debug or release build of the worker
# (cd worker && cargo build), and the deps bundle (deps/<platform>, or set
# FFMPEG). DeepFilterNet cases run when the add-on is installed in addons/
# (or DEEP_FILTER points at deep-filter 0.5.6). The AVFoundation read (F4)
# runs on macOS only.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
: "${WORK:?set WORK to a scratch directory}"
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) PLAT=macos-arm64 ;; Darwin-x86_64) PLAT=macos-x64 ;;
  Linux-x86_64) PLAT=linux-x64 ;; Linux-aarch64) PLAT=linux-arm64 ;; *) PLAT=windows-x64 ;;
esac
: "${FFMPEG:=$REPO/deps/$PLAT/ffmpeg/ffmpeg}"
: "${SPEECH:=$REPO/Tests/TestResources/small_clip.mp4}"
if [ -z "$WORKER" ]; then
  for w in "$REPO/worker/target/release/vapourbox-worker" "$REPO/worker/target/debug/vapourbox-worker"; do
    [ -x "$w" ] && WORKER="$w" && break
  done
fi
if [ -z "$DEEP_FILTER" ]; then
  for f in "$REPO"/addons/deepfilternet/deep-filter-0.5.6-*; do
    [ -x "$f" ] && DEEP_FILTER="$f"
  done
fi
export WORK FFMPEG SPEECH WORKER
[ -n "$DEEP_FILTER" ] && export DEEP_FILTER
mkdir -p "$WORK"
"$FFMPEG" -version | head -1
"${PYTHON:-python3}" "$HERE/pcm_depth_probe.py" > "$WORK/pcm_depth.jsonl"
cat "$WORK/pcm_depth.jsonl"
"$HERE/data_rates.sh"
"${PYTHON:-python3}" "$HERE/chart.py"
if [ "$(uname -s)" = Darwin ]; then
  swiftc -O -suppress-warnings "$HERE/avf_read.swift" -o "$WORK/avf_read"
  for f in "$WORK"/mux/prores_mov.mov "$WORK"/mux/v210_mov.mov; do
    echo "== AVFoundation: $(basename "$f")"
    "$WORK/avf_read" "$f" "$WORK/$(basename "$f").avf.s32"
    "$FFMPEG" -v error -i "$f" -map 0:a:0 -f s32le - > "$WORK/$(basename "$f").ff.s32"
    if cmp -s "$WORK/$(basename "$f").avf.s32" "$WORK/$(basename "$f").ff.s32"; then
      echo "samples: identical to ffmpeg's decode ($(wc -c < "$WORK/$(basename "$f").ff.s32") bytes)"
    else
      echo "samples: DIFFER from ffmpeg's decode"
    fi
  done
fi
# F6: the AVI fixtures, their headers, and VLC's read where VLC is installed.
# The Windows readers run on a GitHub runner (see the report's Reproduce).
"${PYTHON:-python3}" "$HERE/avi_readers/make_fixtures.py"
: "${VLC:=$( [ -x /Applications/VLC.app/Contents/MacOS/VLC ] && echo /Applications/VLC.app/Contents/MacOS/VLC || command -v vlc || true)}"
if [ -n "$VLC" ]; then
  VLC="$VLC" "$HERE/avi_readers/vlc_read.sh"
  "${PYTHON:-python3}" "$HERE/avi_readers/compare.py"
fi
