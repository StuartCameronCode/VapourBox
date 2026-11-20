#!/usr/bin/env bash
# Task #75: the quick probe's time (or timeout) in every job of the last N
# ci-test.yml runs, from the logs. Needs gh, authenticated.
#   ci_quick_probe_times.sh [N]
set -euo pipefail
N=${1:-25}
TMP=$(mktemp -d)
for run in $(gh run list --workflow ci-test.yml --limit "$N" --status completed --json databaseId --jq '.[].databaseId'); do
  gh api "repos/{owner}/{repo}/actions/runs/$run/jobs?per_page=50" \
     --jq '.jobs[] | "\(.id)\t\(.name)"' | while IFS=$'\t' read -r job name; do
    gh run view --job "$job" --log > "$TMP/$job.log" 2>/dev/null || continue
    q=$(grep -oE "quick probe: [0-9]+ s|probe finished: exit [0-9-]+ after [0-9]+ s" "$TMP/$job.log" | head -1 || true)
    grep -q "TimeoutException after 0:15" "$TMP/$job.log" && q="TIMEOUT"
    deps=$(grep -oE "deps-v1\.[0-9]+\.[0-9]+(-rc[0-9]+)?" "$TMP/$job.log" | head -1 || true)
    printf '%s\t%s\t%s\t%s\n' "$run" "$name" "${q:-?}" "${deps:-?}"
    rm -f "$TMP/$job.log"
  done
done
rmdir "$TMP"
