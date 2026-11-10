#!/bin/bash
# Reproduce every number and image in the report.
#
#   BEFORE_WORKER=<debug worker built from the commit before the fix> ./run.sh
#
# The "after" worker is this checkout's debug build (cd worker && cargo build).
# Build the "before" one from the parent of the fix commit, in a checkout that
# also has deps/ (debug workers find deps/ by searching upward from themselves).
# Scratch files go to $SEEK_WORK (default: a temporary directory); results are
# written there as *.txt / *.json. Needs deps/<platform> (or $VAPOURBOX_DEPS_DIR).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
AFTER="${AFTER_WORKER:-$REPO/worker/target/debug/vapourbox-worker}"
BEFORE="${BEFORE_WORKER:?set BEFORE_WORKER to a worker built without the fix}"
export SEEK_WORK="${SEEK_WORK:-$(mktemp -d)}"
cd "$HERE"
python3 make_variants.py
python3 dup_probe.py --json "$SEEK_WORK/dup.json" | tee "$SEEK_WORK/dup.txt"
for v in before after; do
    w=$BEFORE; [ $v = after ] && w=$AFTER
    python3 worker_probe.py --worker "$w" --json "$SEEK_WORK/worker_$v.json" | tee "$SEEK_WORK/worker_$v.txt"
done
python3 frame0_probe.py --before "$BEFORE" --after "$AFTER" | tee "$SEEK_WORK/frame0.txt"
python3 identity_probe.py --before "$BEFORE" --after "$AFTER" | tee "$SEEK_WORK/identity.txt"
python3 telecine_probe.py --before "$BEFORE" --after "$AFTER" | tee "$SEEK_WORK/telecine.txt"
python3 detector_probe.py --before "$BEFORE" --after "$AFTER" | tee "$SEEK_WORK/detectors.txt"
python3 gap_probe.py | tee "$SEEK_WORK/gap.txt"
python3 images.py --before "$BEFORE" --after "$AFTER"
echo "Results in $SEEK_WORK"
