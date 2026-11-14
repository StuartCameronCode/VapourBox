#!/bin/bash
# Reproduce every number and image in the report.
#
#   BEFORE_WORKER=<debug worker built from the commit before the fix> ./run.sh
#
# The "after" worker is this checkout's debug build (cd worker && cargo build).
# A debug worker finds its templates beside the executable or by searching
# upward from it, and deps in repo deps/ or the installed bundle; the "before"
# one is easiest built from `git archive` of the parent commit, with
# worker/templates copied next to its executable.
# Scratch files go to $SEEK_WORK (default: a temporary directory). Needs
# deps/<platform> (or $VAPOURBOX_DEPS_DIR) for ffmpeg/ffprobe.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
AFTER="${AFTER_WORKER:-$REPO/worker/target/debug/vapourbox-worker}"
BEFORE="${BEFORE_WORKER:?set BEFORE_WORKER to a worker built without the fix}"
export SEEK_WORK="${SEEK_WORK:-$(mktemp -d)}"
cd "$HERE"
python3 make_variants.py
python3 landing_probe.py | tee "$SEEK_WORK/landing.txt"
python3 seek_probe.py --json "$SEEK_WORK/seek.json" | tee "$SEEK_WORK/seek.txt"
python3 raw_es_probe.py | tee "$SEEK_WORK/raw_es.txt"
python3 cost_probe.py | tee "$SEEK_WORK/cost.txt"
python3 discontinuity_probe.py | tee "$SEEK_WORK/discontinuity.txt"
for v in before after; do
    w=$BEFORE; [ $v = after ] && w=$AFTER
    python3 worker_probe.py --worker "$w" --label $v --json "$SEEK_WORK/worker_$v.json" | tee "$SEEK_WORK/worker_$v.txt"
done
python3 detector_probe.py --before "$BEFORE" --after "$AFTER" | tee "$SEEK_WORK/detectors.txt"
python3 images.py --before "$BEFORE" --after "$AFTER"
echo "Results in $SEEK_WORK"
