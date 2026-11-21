#!/bin/bash
# Reproduces every number in ../index.html on an Apple Silicon Mac.
#
#   SCRATCH=/some/scratch/dir [BASE=<git rev>] ./reproduce.sh
#
# Needs, unzipped from the deps release the app pins (deps-version.json):
#   deps/macos-arm64   the arm64 bundle
#   deps/macos-x64     the x64 bundle (run under Rosetta: its znedi3 is the
#                      x86 build, which refuses what arm64's nnedi3 accepts)
# and the worker built twice: `cargo build` and
# `cargo build --target x86_64-apple-darwin` (rustup target add first).
# BASE is the commit before task #81's change (its templates are "before").
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
S="${SCRATCH:?set SCRATCH to your scratch directory}"
BASE="${BASE:-0618c709}"
DATA="$HERE/../data"
mkdir -p "$S/before"
git -C "$REPO" archive "$BASE" worker/templates | tar -x -C "$S/before"

bundle() {  # bundle <deps dir> <args...>: the bundle's Python and environment
  local D="$1"; shift
  PYTHONHOME="$D/python" PYTHONPATH="$D:$D/python-packages" PYTHONNOUSERSITE=1 \
    XDG_CONFIG_HOME="$D/config" "$D/python/bin/python3" "$@"
}

# 1. The probe: the four calls, x86 (Rosetta) checked against the table.
VAPOURBOX_PLATFORM=macos-x64 bundle "$REPO/deps/macos-x64" "$REPO/Scripts/probe-plugin-formats.py" \
  --ffmpeg "$REPO/deps/macos-x64/ffmpeg/ffmpeg" \
  --calls nnedi3.nnedi3,havsfunc.daa,bwdif.Bwdif,mpeg2stinx,vivtc.VFM \
  --check "$REPO/Tests/TestResources/plugin_format_table.json" | tee "$DATA/x64_probe_check.txt"

# 2. Every NNEDI3 path as a real job, before and after, x86 and arm64.
X86="$REPO/worker/target/x86_64-apple-darwin/debug/vapourbox-worker"
ARM="$REPO/worker/target/debug/vapourbox-worker"
python3 "$HERE/x86_paths.py" "$X86" "$S/x86" "$S/before/worker/templates" > "$DATA/x86_before.jsonl"
python3 "$HERE/x86_paths.py" "$X86" "$S/x86" > "$DATA/x86_after.jsonl"
python3 "$HERE/x86_paths.py" "$ARM" "$S/arm" > "$DATA/arm64_after.jsonl"

# 3. What the padding changes on arm64, where nnedi3 took the frame unpadded.
"$REPO/deps/macos-arm64/ffmpeg/ffmpeg" -v error -y -i "$REPO/Tests/TestResources/interlaced_test.avi" \
  -frames:v 10 -vf scale=720:486:flags=bicubic -pix_fmt yuv444p16le -f rawvideo "$S/d1_444p16.yuv"
bundle "$REPO/deps/macos-arm64" "$HERE/arm64_pad_change.py" "$S/d1_444p16.yuv" 10 > "$DATA/arm64_pad_change.json"
