#!/bin/bash
# Reproduce every number in the report, in order. Needs Python 3 with NumPy,
# the repo's deps bundle (deps/<platform>), and worker builds:
#   cd worker && cargo build && cargo build --release
# SCRATCH holds the downloads (~180 MB) and fixtures (~1.5 GB).
# Takes about an hour on an M1 Pro, most of it the NumPy reference.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${SCRATCH:?set SCRATCH to your scratch directory}"
PY="${PYTHON:-python3}"
cd "$HERE"
bash fetch_sources.sh
"$PY" build_fixtures.py
"$PY" measure_candidates.py           # candidates.json: the rejected measures
"$PY" measure_final.py                # final.json: the chosen measures
"$PY" worker_parity.py                # parity.json: the Rust worker, same pairs
WORKER="${WORKER:-$HERE/../../../../worker/target/release/vapourbox-worker}" "$PY" timing.py
bash images.sh
"$PY" fill_report.py
# The exploration tables quoted in the report:
#   $PY explore.py noise-spatial; R=10 $PY explore.py noise-mc
#   $PY explore.py halo-zone; $PY explore.py halo-reach; $PY explore.py halo-flat
