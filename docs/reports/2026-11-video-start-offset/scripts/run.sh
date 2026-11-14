#!/bin/bash
# Reproduce every number and image in the report.
#
#   BEFORE_WORKER=<debug worker built from the commit before the fix> ./run.sh
#
# The "after" worker is this checkout's debug build (cd worker && cargo build).
# Build the "before" one from the parent of the fix, in a checkout that also
# has deps/ (debug workers find deps/ by searching upward from themselves).
# Fixtures: Tests/TestResources/generate_video_start_offset.sh (committed).
# Scratch files go to $OFFSET_WORK (default: a temporary directory); results
# are written there as *.txt / *.json. Needs deps/<platform> (or
# $VAPOURBOX_DEPS_DIR).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
AFTER="${AFTER_WORKER:-$REPO/worker/target/debug/vapourbox-worker}"
BEFORE="${BEFORE_WORKER:?set BEFORE_WORKER to a worker built without the fix}"
export OFFSET_WORK="${OFFSET_WORK:-$(mktemp -d)}"
cd "$HERE"
python3 offset_probe.py --json "$OFFSET_WORK/offsets.json" | tee "$OFFSET_WORK/offsets.txt"
python3 frame_probe.py --before "$BEFORE" --after "$AFTER" --json "$OFFSET_WORK/frames.json" | tee "$OFFSET_WORK/frames.txt"
python3 sync_probe.py --before "$BEFORE" --after "$AFTER" --json "$OFFSET_WORK/sync.json" | tee "$OFFSET_WORK/sync.txt"
python3 identity_probe.py --before "$BEFORE" --after "$AFTER" | tee "$OFFSET_WORK/identity.txt"
python3 images.py --before "$BEFORE" --after "$AFTER"
echo "Results in $OFFSET_WORK"
