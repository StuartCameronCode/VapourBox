#!/usr/bin/env bash
# Run the raw tail probe the worker runs for small_clip.mp4 (the last 3 s of
# video packets, task #54) N times, P at once, and record each run's exit
# status, line count and stderr: whether ffprobe itself drops out, without
# the worker in the way (task #83).
#
#   bash ffprobe_tail_loop.sh <ffprobe> <file> <runs> <parallel> <out-dir> [interval]
#
# interval defaults to 102.119% (small_clip.mp4: 105.119 s less 3 s).
set -uo pipefail
FFPROBE="${1:?ffprobe}"; FILE="${2:?file}"; RUNS="${3:?runs}"; PAR="${4:?parallel}"; OUT="${5:?out dir}"
INTERVAL="${6:-102.119%}"
mkdir -p "$OUT/runs"
one() {
  local i="$1"
  "$FFPROBE" -v error -select_streams v:0 -show_entries packet=pts_time,flags \
    -read_intervals "$INTERVAL" -of csv=p=0 "$FILE" >"$OUT/runs/$i.out" 2>"$OUT/runs/$i.err"
  echo $? >"$OUT/runs/$i.status"
}
export -f one; export FFPROBE FILE OUT INTERVAL
seq 1 "$RUNS" | xargs -P "$PAR" -I{} bash -c 'one {}'
: >"$OUT/summary.txt"
for i in $(seq 1 "$RUNS"); do
  printf '%s status=%s lines=%s stderr_bytes=%s\n' "$i" "$(cat "$OUT/runs/$i.status")" \
    "$(grep -c . "$OUT/runs/$i.out")" "$(wc -c <"$OUT/runs/$i.err" | tr -d ' ')" >>"$OUT/summary.txt"
done
echo "== raw tail probe: $RUNS runs, $PAR at once"
cut -d' ' -f2- "$OUT/summary.txt" | sort | uniq -c
