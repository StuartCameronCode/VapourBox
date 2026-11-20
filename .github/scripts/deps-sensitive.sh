#!/usr/bin/env bash
# Does this CI run touch the deps bundle, the plugin format table or the
# probe that compares them? Prints `true` or `false` (task #84).
#
# ci-test.yml runs the quick plugin format probe (tagged `heavy`, otherwise
# nightly only) when it does: a deps update that changes a plugin's limits
# must fail before it merges, not the next morning.
#
# True when:
#   * DEPS_RUN_ID is set (a workflow_dispatch testing an unpublished bundle),
#   * HEAD^1..HEAD changes one of PATTERNS below (on a pull_request, HEAD is
#     GitHub's merge commit and HEAD^1 the base branch, so this is the whole
#     PR; on a push to main, the merged change). The checkout needs
#     `fetch-depth: 2`;
#   * HEAD^1 is not there to compare with (better to run than to skip).
#
# Usage: deps-sensitive.sh [<base> [<head>]]   (default HEAD^1 HEAD)
set -euo pipefail

PATTERNS=(
  'app/assets/deps-version.json'
  'Tests/TestResources/plugin_format_table.json'
  'Scripts/probe-plugin-formats.py'
  'Scripts/download-deps-*'
  'Scripts/deps-expected-plugins.json'
  'worker/templates/plugin_formats.py'
  'app/test/plugin_format_contracts_test.dart'
  'app/test/support/plugin_probe_runner.dart'
  '.github/scripts/deps-sensitive.sh'
)

if [ -n "${DEPS_RUN_ID:-}" ]; then
  echo "deps-sensitive: deps_run_id given" >&2
  echo true
  exit 0
fi

base="${1:-HEAD^1}"
head="${2:-HEAD}"
if ! changed=$(git diff --name-only "$base" "$head" 2>/dev/null); then
  echo "deps-sensitive: cannot diff $base..$head, running the checks" >&2
  echo true
  exit 0
fi

while IFS= read -r file; do
  [ -z "$file" ] && continue
  for pattern in "${PATTERNS[@]}"; do
    # The pattern is a glob on purpose.
    # shellcheck disable=SC2053
    if [[ "$file" == $pattern ]]; then
      echo "deps-sensitive: $file" >&2
      echo true
      exit 0
    fi
  done
done <<< "$changed"

echo false
