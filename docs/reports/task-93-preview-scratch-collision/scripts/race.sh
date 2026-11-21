#!/bin/bash
# Task #93: previews of one job, three at a time, as the IVTC repeat test
# (integration_ivtc_preview_test.dart) runs them, counted and checked against
# each frame previewed alone.
#
#   VB_SCRATCH=/some/scratch/dir ./race.sh [shared|unique] [rounds] [busy_cores]
#
# shared: every preview gets the same job (one job id), as the test does.
# unique: each frame gets a job of its own (a different id).
# busy_cores: busy loops kept running alongside, to stagger the workers.
#
# Uses worker/target/debug/vapourbox-worker (run `cargo build` in worker/
# first) and whatever deps bundle that debug worker finds. Prints
# "ok=… wrong_picture=… failed=…" over rounds × 36 previews.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
WORKER_DIR="$REPO/worker/target/debug"
MODE="${1:-shared}"; ROUNDS="${2:-10}"; BUSY="${3:-6}"
: "${VB_SCRATCH:?set VB_SCRATCH to a scratch directory}"
mkdir -p "$VB_SCRATCH/jobs" "$VB_SCRATCH/ref"
SRC="$REPO/Tests/TestResources/prores422_10bit_telecine.mov"

job() {  # job <uuid-suffix> -> job JSON: the test's ProRes IVTC job
  cat <<JSON
{"id":"9393a0a0-0000-4000-8000-0000000000$1","inputPath":"$SRC","outputPath":"$VB_SCRATCH/out.mkv",
 "qtgmcParameters":{"enabled":true,"method":"ivtc","tff":true,"ivtcCycle":5},
 "processingPipeline":{"deinterlace":{"enabled":true,"method":"ivtc","tff":true,"ivtcCycle":5}},
 "encodingSettings":{"codec":"ffv1","container":"mkv","audioMode":"none"},
 "detectedFieldOrder":"tff","inputWidth":720,"inputHeight":480,"inputPixelFormat":"yuv422p10le",
 "inputFrameRate":29.97002997,"totalFrames":30}
JSON
}
job 99 > "$VB_SCRATCH/jobs/shared.json"
for f in $(seq 0 29); do job "$(printf %02d "$f")" > "$VB_SCRATCH/jobs/$f.json"; done
config() { if [ "$MODE" = shared ]; then echo "$VB_SCRATCH/jobs/shared.json"; else echo "$VB_SCRATCH/jobs/$1.json"; fi; }

preview() {  # preview <config> <frame> <out-prefix>
  (cd "$WORKER_DIR" && ./vapourbox-worker --config "$1" --preview --frame "$2" > "$3.png" 2> "$3.err")
}

# Each frame alone, one at a time: the reference picture.
for f in $(seq 0 29); do
  [ -s "$VB_SCRATCH/ref/$f.md5" ] && continue
  preview "$VB_SCRATCH/jobs/$f.json" "$f" "$VB_SCRATCH/ref/$f" || { echo "reference $f failed"; exit 1; }
  md5 -q "$VB_SCRATCH/ref/$f.png" > "$VB_SCRATCH/ref/$f.md5" 2>/dev/null \
    || md5sum "$VB_SCRATCH/ref/$f.png" | cut -d' ' -f1 > "$VB_SCRATCH/ref/$f.md5"
done
sum() { md5 -q "$1" 2>/dev/null || md5sum "$1" | cut -d' ' -f1; }

busy=()
for _ in $(seq 1 "$BUSY"); do (while :; do :; done) & busy+=($!); done
trap 'kill "${busy[@]}" 2>/dev/null' EXIT

ok=0; wrong=0; failed=0
mkdir -p "$VB_SCRATCH/errors"
for r in $(seq 1 "$ROUNDS"); do
  rm -rf "$VB_SCRATCH/run"; mkdir "$VB_SCRATCH/run"
  for i in $(seq 0 3 35); do
    pids=()
    for k in 0 1 2; do
      f=$(( ((i + k) * 7) % 30 ))
      ( sleep "0.$(( RANDOM % 40 ))"; preview "$(config "$f")" "$f" "$VB_SCRATCH/run/${i}_$f" ) &
      pids+=($!)
    done
    wait "${pids[@]}"
  done
  for png in "$VB_SCRATCH"/run/*.png; do
    f="$(basename "$png" .png)"; f="${f##*_}"
    if [ ! -s "$png" ]; then
      failed=$((failed + 1)); cp "${png%.png}.err" "$VB_SCRATCH/errors/r${r}_$(basename "${png%.png}").err"
    elif [ "$(sum "$png")" = "$(cat "$VB_SCRATCH/ref/$f.md5")" ]; then ok=$((ok + 1))
    else wrong=$((wrong + 1)); fi
  done
done
echo "mode=$MODE rounds=$ROUNDS busy=$BUSY ok=$ok wrong_picture=$wrong failed=$failed"
echo "failed previews' messages:"
grep -h "Error generating preview" "$VB_SCRATCH"/errors/*.err 2>/dev/null | sed -E 's/line [0-9]+/line N/; s/0x[0-9a-f]+/0x…/; s/[0-9a-f-]{36}/<job id>/' | sort | uniq -c
