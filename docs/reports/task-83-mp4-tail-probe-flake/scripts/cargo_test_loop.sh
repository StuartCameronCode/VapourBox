#!/usr/bin/env bash
# Run the Rust tests that probe small_clip.mp4 N times, as the push gate runs
# them (task #83). Run from worker/.
#
#   bash cargo_test_loop.sh <runs> <out-dir>
set -uo pipefail
RUNS="${1:?runs}"; OUT="${2:?out dir}"
mkdir -p "$OUT"
pass=0; fail=0
for i in $(seq 1 "$RUNS"); do
  if cargo test --test continuity_integration_test --test source_model_integration_test -- --nocapture \
      >"$OUT/run_$i.log" 2>&1; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "run $i failed"; grep -n "panicked\|failed (attempt" "$OUT/run_$i.log" | head -20
  fi
done
echo "== cargo test x$RUNS: $pass passed, $fail failed"
grep -h "failed (attempt" "$OUT"/run_*.log | sort | uniq -c | head -20
