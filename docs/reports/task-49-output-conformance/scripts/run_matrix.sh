#!/usr/bin/env bash
# Task #49: run the output conformance matrix and summarise it.
# Usage (from the repo root, after `cd worker && cargo build`):
#   docs/reports/task-49-output-conformance/scripts/run_matrix.sh > matrix_<platform>.txt
# Honours VAPOURBOX_DEPS_DIR like every heavy test.
set -u
cd app || exit 1
log=$(mktemp)
flutter test --tags heavy test/integration_output_conformance_test.dart -r expanded >"$log" 2>&1
grep -E '^[0-9]+:[0-9]+ .*(All tests passed|Some tests failed)' "$log" | tail -1
echo "failures (case :: first failed check):"
awk '/\[E\]$/{cur=$0; sub(/^.*: /,"",cur); sub(/ \[E\]$/,"",cur)} /^  [0-9]\. /{if(cur!=""){print cur" :: "$0; cur=""}}' "$log"
rm -f "$log"
