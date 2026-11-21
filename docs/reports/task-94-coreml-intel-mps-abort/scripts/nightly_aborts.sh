#!/usr/bin/env bash
# Task #94: which macOS nightly jobs aborted in Metal Performance Shaders.
#
# For each nightly run given (default: those of 2026-11-15 .. 2026-11-20),
# downloads every macOS job's log with gh and prints one line per job: run,
# job id, job name, conclusion, whether the log has the MPS kernel compile
# abort (MPSLibrary / "unable to load function" / "Compilation failed"), the
# kernel named, and the failed test reported with it. Needs `gh` authenticated for
# the repository.
#
#   scripts/nightly_aborts.sh [run-id ...] > data/nightly_aborts.tsv
set -euo pipefail
REPO=${REPO:-StuartCameronCode/VapourBox}
RUNS=("$@")
if [ ${#RUNS[@]} -eq 0 ]; then
  RUNS=(43735840276 43909344002 44089342398 44127090331 44342418084 44515333102 44562921675 44767156916)
fi
CACHE=${CACHE:-$(mktemp -d)}
printf 'run\tjob\tname\tconclusion\tmps_abort\tkernel\ttest\n'
for run in "${RUNS[@]}"; do
  gh api "repos/$REPO/actions/runs/$run/jobs?per_page=100" \
    --jq '.jobs[] | select(.name | startswith("macos")) | "\(.id)\t\(.name)\t\(.conclusion)"' |
  while IFS=$'\t' read -r job name conclusion; do
    log="$CACHE/$run-$job.log"
    [ -s "$log" ] || gh api "repos/$REPO/actions/jobs/$job/logs" --allow-escape-sequences 2>/dev/null |
      tr -d '\033' > "$log" || true
    if grep -qE 'MPSLibrary|unable to load function|Compilation failed' "$log"; then
      abort=yes
      kernel=$(grep -oE 'unable to load function [A-Za-z0-9_]+' "$log" | head -1 | awk '{print $NF}' || true)
      # The test line printed last before the abort.
      first=$(grep -nE 'MPSLibrary|unable to load function|Compilation failed' "$log" | head -1 | cut -d: -f1 || true)
      # The failed test reported just above the abort (the expanded reporter's
      # "❌ <file>: <test> (failed)" group header).
      test=$(head -n "$first" "$log" | grep -E '❌ ' | tail -1 |
        sed -E 's/.*❌ [^ ]*\/([^/]+\.dart): /\1: /; s/ \(failed\)$//' | cut -c1-200 || true)
    else
      abort=no; kernel=; test=
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$run" "$job" "$name" "$conclusion" "$abort" "$kernel" "$test"
  done
done
