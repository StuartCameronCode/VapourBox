#!/usr/bin/env bash
# Task #94: the ai-runtime encodes' wall times in the macOS nightly heavy jobs
# (integration_colorize_test.dart / integration_face_restore_test.dart print
# "  <name>: <s>s for 16 frames"). Reads the logs nightly_aborts.sh cached
# (CACHE=<dir>), or downloads the jobs of the runs given.
#
#   CACHE=<dir> scripts/nightly_timings.sh [run-id ...] > data/nightly_timings.tsv
set -euo pipefail
REPO=${REPO:-StuartCameronCode/VapourBox}
CACHE=${CACHE:?set CACHE to the directory of <run>-<job>.log files}
for run in "$@"; do
  gh api "repos/$REPO/actions/runs/$run/jobs?per_page=100" \
    --jq '.jobs[] | select(.name | startswith("macos")) | .id' | while read -r job; do
    log="$CACHE/$run-$job.log"
    [ -s "$log" ] || gh api "repos/$REPO/actions/jobs/$job/logs" --allow-escape-sequences | tr -d '\033' > "$log"
  done
done
printf 'run\tjob\tencode\tseconds\n'
for log in "$CACHE"/*.log; do
  b=$(basename "$log" .log)
  grep -oE '  (ddcolor|strength0|deoldify|ddcolor_10bit|colour_ddcolor|preview_ref|restoreformer|restoreformer_10bit|gfpgan[a-z_]*|codeformer[a-z_]*): [0-9.]+s for 16 frames' "$log" |
    sed -E "s/^  ([a-z0-9_]+): ([0-9.]+)s.*/${b%%-*}\t${b#*-}\t\1\t\2/" || true
done
