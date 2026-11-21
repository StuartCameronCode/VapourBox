#!/usr/bin/env bash
# Task #91: fetch what sweep_timings.py reads, for the nightly runs given: each
# run's format-sweep-<bundle> result artefacts (per-row preview times) and the
# logs of its sweep jobs (the delta-only groups' finish times and failures).
# Needs gh, authenticated.
#
#   CACHE=<dir> scripts/fetch.sh 44562921675 44869849455 [run-id ...]
set -euo pipefail
REPO=${REPO:-StuartCameronCode/VapourBox}
CACHE=${CACHE:?set CACHE to a directory for the downloads}
for run in "$@"; do
  mkdir -p "$CACHE/$run"
  for name in $(gh api "repos/$REPO/actions/runs/$run/artifacts?per_page=100" \
      --jq '.artifacts[] | select(.name | startswith("format-sweep-")) | .name'); do
    [ -d "$CACHE/$run/$name" ] || gh run download "$run" --repo "$REPO" -n "$name" -D "$CACHE/$run/$name"
  done
  gh api "repos/$REPO/actions/runs/$run/jobs?per_page=100" \
    --jq '.jobs[] | select(.name | endswith(", sweep)")) | "\(.id)\t\(.name)"' |
  while IFS=$'\t' read -r job jname; do
    bundle=$(sed -E 's/^[a-z]+ \(([^,]+), sweep\)$/\1/' <<<"$jname")
    log="$CACHE/$run/$bundle.log"
    [ -s "$log" ] || gh api "repos/$REPO/actions/jobs/$job/logs" --allow-escape-sequences | tr -d '\033' > "$log"
  done
done
