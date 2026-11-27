#!/usr/bin/env bash
# Download a zimg-9806db42-check.yml run's artifacts into DATA/linux/<run>/
# and print their summaries (task #126). Needs gh.
# Usage: collect.sh RUN_ID DATA_DIR
set -euo pipefail
RUN=$1 DATA=$2
OUT="$DATA/linux/$RUN"
mkdir -p "$OUT"
gh run download "$RUN" -R StuartCameronCode/VapourBox -D "$OUT"
# Keep the summaries and the ASan tables (task #115 reads them); every other
# per-case table stays in the run's artifacts.
find "$OUT" -type f -name '*.tsv' ! -name summary.tsv ! -name compare.tsv \
    ! -name digest-diff.tsv ! -name repro.tsv ! -name '*-asan.tsv' -delete
for d in "$OUT"/*/; do
    echo "== $(basename "$d")"
    cat "$d/summary.tsv" "$d/compare.tsv" "$d/repro.tsv"
    tail -n +2 "$d/digest-diff.tsv"
done
