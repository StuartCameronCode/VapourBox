#!/usr/bin/env bash
# Summarise one ci-test or nightly run's Linux failures (task #103).
#
#   linux_failures.sh <run-id>
#
# Prints each Linux job's conclusion, then every failing Flutter test (the
# reporter's ❌ lines), every failing Rust test, and how many of the failures
# are a vspipe SIGABRT. Needs `gh` authenticated for the repository.
set -euo pipefail
run="$1"
log=$(mktemp)
trap 'rm -f "$log"' EXIT

echo "== run $run"
gh run view "$run" --json jobs \
    --jq '.jobs[] | select(.name | test("linux")) | "  \(.name): \(.conclusion)"'
gh run view "$run" --log-failed > "$log" 2>/dev/null || true

# Each log line is "<job>\t<step>\t<timestamp> <text>".
linux=$(grep -aE '^[^	]*linux[^	]*	' "$log" | cut -f1,3- | sed -E 's/	[0-9T:.Z-]+ /	/' || true)

echo "-- failing Flutter tests"
printf '%s\n' "$linux" | grep -a '##\[group\]❌' \
    | sed -E 's/##\[group\]❌ [^ ]*\/app\/test\//  /; s/ \(failed\)$//' | sort -u || true
echo "-- failing Rust tests"
printf '%s\n' "$linux" | grep -aE 'test [^ ]+ \.\.\. FAILED' \
    | sed -E 's/.*test ([^ ]+) \.\.\. FAILED/  \1/' | sort -u || true
echo "-- SIGABRT / double free lines: $(printf '%s\n' "$linux" \
    | grep -acE 'signal 6|SIGABRT|double free' || true)"
