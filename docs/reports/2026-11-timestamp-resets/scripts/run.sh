#!/bin/bash
# Reproduce every number in the report (task #21).
#
# Needs this checkout's debug worker (cd worker && cargo build) and deps for
# ffmpeg/ffprobe (repo deps/<platform> or $VAPOURBOX_DEPS_DIR). Scratch files
# go to $RESET_WORK (default: a temporary directory). The fixtures are
# Tests/TestResources/seek_reset_* (generate_mpeg_seek_test.sh).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export RESET_WORK="${RESET_WORK:-$(mktemp -d)}"
mkdir -p "$RESET_WORK"
cd "$HERE"
python3 before_after_probe.py | tee "$RESET_WORK/before_after.txt"
python3 fixtures_probe.py | tee "$RESET_WORK/fixtures.txt"
python3 cost_probe.py | tee "$RESET_WORK/cost.txt"
echo "Results in $RESET_WORK"
