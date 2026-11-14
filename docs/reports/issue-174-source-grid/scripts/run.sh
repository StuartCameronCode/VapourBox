#!/bin/bash
# Reproduce every number and image in the report.
#
#   BEFORE_WORKER=<debug worker built without the fix> ./run.sh
#
# The "after" worker is this checkout's debug build (cd worker && cargo build).
# Build the "before" one from the commit before the fix, in a tree that also
# has deps/ (a debug worker finds deps/ by searching upward from itself) and
# worker/templates copied next to the binary. Fixtures come from
# Tests/TestResources (generate_source_grid_test.sh makes the new ones).
# Scratch files and results go to $GRID_WORK (default: a temporary directory).
# Needs deps/<platform> (or $VAPOURBOX_DEPS_DIR).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
AFTER="${AFTER_WORKER:-$REPO/worker/target/debug/vapourbox-worker}"
BEFORE="${BEFORE_WORKER:?set BEFORE_WORKER to a worker built without the fix}"
export GRID_WORK="${GRID_WORK:-$(mktemp -d)}"
cd "$HERE"
python3 rate_probe.py | tee "$GRID_WORK/rates.txt"
python3 slot_probe.py --json "$GRID_WORK/slots.json" | tee "$GRID_WORK/slots.txt"
python3 seek_probe.py --json "$GRID_WORK/seeks.json" | tee "$GRID_WORK/seeks.txt"
python3 reset_probe.py | tee "$GRID_WORK/reset.txt"
python3 worker_probe.py --worker "$BEFORE" --app before --json "$GRID_WORK/worker_before.json" | tee "$GRID_WORK/worker_before.txt"
python3 worker_probe.py --worker "$AFTER" --app after --json "$GRID_WORK/worker_after.json" | tee "$GRID_WORK/worker_after.txt"
python3 images.py --before "$BEFORE" --after "$AFTER"
echo "Results in $GRID_WORK"
