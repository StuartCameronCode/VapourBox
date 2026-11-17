#!/usr/bin/env bash
# Task #65: the IVTC preview loop with main's template and with this
# branch's, side by side, each as 4 concurrent loops under CPU load (the
# nightly ran its previews beside the rest of the heavy suite). Run from the
# repository root after `cd worker && cargo build`:
#
#   compare_templates.sh <main-ref> <out-dir>
#
# Each side is a copy of the debug worker with its own templates/ beside it,
# which the worker searches first. Writes <out-dir>/summary.txt.
set -u
REF="$1"; OUT="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN=worker/target/debug
mkdir -p "$OUT"
for side in main branch; do
  rm -rf "${BIN:?}/${side:?}"; mkdir -p "$BIN/$side"
  cp "$BIN/vapourbox-worker" "$BIN/$side/"
  cp -R worker/templates "$BIN/$side/templates"
done
git show "$REF:worker/templates/pipeline_template.vpy" > "$BIN/main/templates/pipeline_template.vpy"
if cmp -s "$BIN/main/templates/pipeline_template.vpy" "$BIN/branch/templates/pipeline_template.vpy"; then
  echo "note: the branch's template is main's" | tee "$OUT/summary.txt"
fi

CPUS=$(getconf _NPROCESSORS_ONLN)
LOAD=""
if command -v stress-ng >/dev/null; then
  stress-ng --cpu "$CPUS" --cpu-load 60 --timeout 0 >/dev/null 2>&1 &
  LOAD=$!
fi
PASSES="${PASSES:-5}"
for side in main branch; do
  for mode in ivtc ivtc-avi bwdif; do
    pids=()
    passes=$([ "$mode" = ivtc-avi ] && echo $(( (PASSES + 2) / 3 )) || echo "$PASSES")
    for k in 1 2 3 4; do
      bash "$HERE/preview_loop.sh" "$BIN/$side/vapourbox-worker" "$mode" "$passes" \
        "$OUT/$side-$mode-$k" > "$OUT/$side-$mode-$k.log" 2>&1 &
      pids+=($!)
    done
    wait "${pids[@]}"
    runs=0; fails=0
    for k in 1 2 3 4; do
      line=$(tail -n1 "$OUT/$side-$mode-$k.log")
      r=$(echo "$line" | sed -n 's/.*runs=\([0-9]*\).*/\1/p'); f=$(echo "$line" | sed -n 's/.*failures=\([0-9]*\).*/\1/p')
      runs=$((runs + ${r:-0})); fails=$((fails + ${f:-0}))
      grep '^FAIL' "$OUT/$side-$mode-$k.log" | head -5
    done
    echo "$side $mode (4 loops, load ${LOAD:+on}${LOAD:-off}): runs=$runs failures=$fails" | tee -a "$OUT/summary.txt"
  done
done
[ -n "$LOAD" ] && kill "$LOAD"
cat "$OUT/summary.txt"
