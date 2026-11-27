#!/bin/sh
# Pull a nightly heavy leg's job log and print what this report reads from it:
# the CPU banner, when the task #96 / #98 stress tests finished (passed, or
# timed out), the per-graph lines (task #124 on), and the runner's orphan
# cleanup at the end of the job.
#
#   scripts/nightly_stress_lines.sh <job id>
#
# Needs an authenticated `gh` in a checkout of the repository. Job ids come
# from `gh run view <run id> --json jobs`.
set -eu
job="$1"
gh run view --job "$job" --log |
  sed 's/^[^\t]*\t[^\t]*\t//' |
  grep -E 'survive many instances|stress [A-Za-z(]|Terminate orphan|Cleaning up orphan|TimeoutException|Some tests failed' |
  sed -E 's/\x1b\[[0-9;]*m//g'

