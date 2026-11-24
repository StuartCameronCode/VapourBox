#!/usr/bin/env bash
# Download a zimg-graphengine-bisect.yml run's artifacts into DATA/linux/<run>/
# and print their summaries (task #109). Needs gh.
# Usage: collect.sh RUN_ID DATA_DIR
set -euo pipefail
RUN=$1 DATA=$2
OUT="$DATA/linux/$RUN"
mkdir -p "$OUT"
gh run download "$RUN" -R StuartCameronCode/VapourBox -D "$OUT"
# Keep the summaries and the per-case tables of the first bad and the last
# commit; drop the rest (every per-case table is in the run's artifacts).
find "$OUT" -type f \( -name '*.build.log' -o -name '*.err' -o -name '*.vg' \) -delete
for d in "$OUT"/c-bisect-*; do
    [ -d "$d" ] || continue
    find "$d" -name '*.tsv' ! -name 'bisect.tsv' ! -name 'patched.tsv' \
        ! -name 'f6211289-*' ! -name '562889d3-*' -delete
    echo "== $(basename "$d")"
    cat "$d/bisect.tsv"
    cat "$d/patched.tsv" 2>/dev/null || true
done
for d in "$OUT"/vs-confirm-*; do
    [ -d "$d" ] || continue
    rm -rf "$d/logs"
    echo "== $(basename "$d")"
    cat "$d/vs-confirm.tsv"
done
