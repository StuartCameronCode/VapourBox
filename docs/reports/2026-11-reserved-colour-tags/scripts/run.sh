#!/bin/bash
# Reproduce every number in the report.
#
#   DEPS=<deps/<platform> dir>   default: the repo's deps/<platform> (macOS arm64 / Linux x64)
#   SCRATCH=<dir>                default: a fresh temp dir
#   CLIP=<a real reserved-tagged source>   optional: adds the real-clip runs
#
# The worker must be built first (cd worker && cargo build).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) PLATFORM=macos-arm64 ;; Darwin-x86_64) PLATFORM=macos-x64 ;;
  Linux-x86_64) PLATFORM=linux-x64 ;; Linux-aarch64) PLATFORM=linux-arm64 ;;
esac
DEPS="${DEPS:-$REPO/deps/$PLATFORM}"
SCRATCH="${SCRATCH:-$(mktemp -d)}"
WORKER="$REPO/worker/target/debug/vapourbox-worker"

python3 -I "$HERE/probe_tag_rules.py" "$DEPS/ffmpeg/ffmpeg" "$DEPS/ffmpeg/ffprobe" \
  "$SCRATCH/rules" ${CLIP:+"$CLIP"}
if [ -n "${CLIP:-}" ]; then
  python3 -I "$HERE/real_clip_worker.py" "$WORKER" "$DEPS" "$CLIP" "$SCRATCH/real"
fi

# Addendum (2026-11-14): Descale Detect's luma no longer follows the matrix tag.
python3 -I "$HERE/luma_scaling_check.py" "$DEPS/ffmpeg/ffmpeg" "$DEPS/ffmpeg/ffprobe" \
  "$SCRATCH/luma" "$WORKER" "$DEPS"
