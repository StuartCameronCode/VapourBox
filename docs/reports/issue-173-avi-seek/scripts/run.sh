#!/bin/bash
# Reproduce every number in the report.
#
#   BEFORE_WORKER=<debug worker built from the commit before the fix> ./run.sh
#
# The "after" worker is this checkout's debug build (cd worker && cargo build).
# Build the "before" one from the parent of the fix commit, in a checkout that
# also has deps/ (debug workers find deps/ by searching upward). Scratch files
# go to $AVI_SEEK_WORK (default: a temporary directory); results are written
# there as *.txt / *.json. Needs deps/<platform> (or $VAPOURBOX_DEPS_DIR) and,
# for the H.264 variants, an ffmpeg with libx264 (the bundled one has it).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
AFTER="${AFTER_WORKER:-$REPO/worker/target/debug/vapourbox-worker}"
BEFORE="${BEFORE_WORKER:?set BEFORE_WORKER to a worker built without the fix}"
export AVI_SEEK_WORK="${AVI_SEEK_WORK:-$(mktemp -d)}"
cd "$HERE"
python3 timestamps.py | tee "$AVI_SEEK_WORK/timestamps.txt"
python3 sweep.py --json "$AVI_SEEK_WORK/sweep.json" | tee "$AVI_SEEK_WORK/sweep.txt"
python3 audio_window.py | tee "$AVI_SEEK_WORK/audio.txt"
python3 worker_probe.py --before "$BEFORE" --after "$AFTER" | tee "$AVI_SEEK_WORK/worker.txt"
python3 images.py --before "$BEFORE" --after "$AFTER"
echo "Results in $AVI_SEEK_WORK"
