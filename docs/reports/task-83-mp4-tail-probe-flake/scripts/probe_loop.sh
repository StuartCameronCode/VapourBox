#!/usr/bin/env bash
# Run `vapourbox-worker --probe-source <file>` N times, P at once, and tally
# the frame counts and every probe failure the worker logged (task #83).
#
#   bash probe_loop.sh <worker> <file> <runs> <parallel> <out-dir>
#
# Writes <out-dir>/counts.txt (one frameCount per run, "ERR" for a failed
# probe), <out-dir>/failures.txt (every "failed (attempt" stderr line, with
# the run number) and prints a tally. Works under Git Bash on Windows.
set -uo pipefail
WORKER="${1:?worker}"; FILE="${2:?file}"; RUNS="${3:?runs}"; PAR="${4:?parallel}"; OUT="${5:?out dir}"
mkdir -p "$OUT/runs"
PY=$(command -v python || command -v python3)
one() {
  local i="$1"
  "$WORKER" --probe-source "$FILE" >"$OUT/runs/$i.out" 2>"$OUT/runs/$i.err"
  echo $? >"$OUT/runs/$i.status"
}
export -f one; export WORKER FILE OUT
seq 1 "$RUNS" | xargs -P "$PAR" -I{} bash -c 'one {}'
: >"$OUT/counts.txt"; : >"$OUT/failures.txt"
for i in $(seq 1 "$RUNS"); do
  c=$("$PY" -c 'import json,sys
try: print(json.load(open(sys.argv[1]))["video"]["frameCount"])
except Exception: print("ERR")' "$OUT/runs/$i.out" 2>/dev/null || echo ERR)
  echo "$c" >>"$OUT/counts.txt"
  grep -h "failed (attempt\|gave no answer\|no kept picture" "$OUT/runs/$i.err" | sed "s/^/run $i: /" >>"$OUT/failures.txt" || true
done
echo "== $(basename "$FILE"): $RUNS runs, $PAR at once"
sort "$OUT/counts.txt" | uniq -c
echo "probe failure lines: $(wc -l <"$OUT/failures.txt")"
head -20 "$OUT/failures.txt"
