#!/bin/sh
# Runs probe_zimg.py with the bundle's own Python and VapourSynth.
# Usage: run.sh [deps-dir]   (default: <repo>/deps/macos-arm64)
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
D="${1:-$REPO/deps/macos-arm64}"
SCRATCH="${VAPOURBOX_PROBE_SCRATCH:-${TMPDIR:-/tmp}}"
mkdir -p "$SCRATCH/task88-config"
# A writable config dir, so the bundle's own is untouched (see CLAUDE.md, R78).
PYTHONHOME="$D/python" PYTHONPATH="$D" XDG_CONFIG_HOME="$SCRATCH/task88-config" \
DYLD_LIBRARY_PATH="$D/lib" LD_LIBRARY_PATH="$D/lib" \
  "$D/python/bin/python3" "$HERE/probe_zimg.py"
