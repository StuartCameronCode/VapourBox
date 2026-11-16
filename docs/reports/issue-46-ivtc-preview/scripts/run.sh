#!/bin/bash
# Reproduce every number and image in the report.
#
#   BEFORE_WORKER=<debug worker built without the fix> ./run.sh
#
# The "after" worker is this checkout's debug build (cd worker && cargo build).
# Build the "before" one from the commit before the fix (38bac59), and put
# that commit's worker/templates next to the binary as templates/ (the worker
# searches beside itself first) and a deps/ above it, or set VAPOURBOX_DEPS_DIR.
# Scratch files go to $IVTC_WORK_ROOT (default: a temporary directory).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
AFTER="${AFTER_WORKER:-$REPO/worker/target/debug/vapourbox-worker}"
BEFORE="${BEFORE_WORKER:?set BEFORE_WORKER to a worker built without the fix}"
ROOT="${IVTC_WORK_ROOT:-$(mktemp -d)}"
mkdir -p "$ROOT/before" "$ROOT/after"
cd "$HERE"
python3 vdecimate_probe.py | tee "$ROOT/vdecimate_probe.txt"
IVTC_WORK="$ROOT/before" python3 measure.py --worker "$BEFORE" --json "$ROOT/before.json" | tee "$ROOT/before.txt"
IVTC_WORK="$ROOT/after" python3 measure.py --worker "$AFTER" --json "$ROOT/after.json" | tee "$ROOT/after.txt"
python3 summary.py "$ROOT/before.json" "$ROOT/after.json" | tee "$ROOT/summary.txt"
python3 images.py --before-work "$ROOT/before" --after-work "$ROOT/after"
echo "Results in $ROOT"
