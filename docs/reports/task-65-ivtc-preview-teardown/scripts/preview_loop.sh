#!/usr/bin/env bash
# Run the worker's preview over and over and count the runs that fail
# (task #65). Run from the repository root:
#
#   preview_loop.sh <worker> <mode> <passes> <out-dir>
#
# <mode> picks the job:
#   ivtc       the ProRes 10-bit telecine fixture through IVTC (decimating),
#              the preview the 2026-11-16 nightly failed on
#   ivtc-avi   hard_telecine_test.avi through IVTC (decimating, 8-bit)
#   bwdif      the ProRes fixture through Bwdif (the control: no decimation)
#
# Each pass previews every source frame. A run that exits non-zero keeps
# its stderr in <out-dir>/fail-<mode>-<pass>-<frame>.err; if a core file
# appears (the caller sets ulimit -c and core_pattern), every thread's
# backtrace goes beside it (needs gdb). The last line printed is
# "<mode> runs=N failures=M".
set -u
WORKER="$1"; MODE="$2"; PASSES="$3"; OUT="$4"
ROOT="$(pwd)"
mkdir -p "$OUT"
JOB="$OUT/job-$MODE.json"
CORES="${CORE_DIR:-$OUT/cores}"

case "$MODE" in
  ivtc|bwdif)
    SRC="$ROOT/Tests/TestResources/prores422_10bit_telecine.mov"
    FMT=yuv422p10le; FRAMES=30
    METHOD=$([ "$MODE" = bwdif ] && echo bwdif || echo ivtc) ;;
  ivtc-avi)
    SRC="$ROOT/Tests/TestResources/hard_telecine_test.avi"
    FMT=yuv420p; FRAMES=90; METHOD=ivtc ;;
  *) echo "unknown mode $MODE" >&2; exit 2 ;;
esac

cat > "$JOB" <<JSON
{"id":"65656565-6565-6565-6565-656565656565","inputPath":"$SRC","outputPath":"$OUT/unused.mkv",
 "qtgmcParameters":{"enabled":true,"method":"$METHOD","tff":true,"ivtcCycle":5},
 "processingPipeline":{"deinterlace":{"enabled":true,"method":"$METHOD","tff":true,"ivtcCycle":5}},
 "encodingSettings":{"codec":"ffv1","container":"mkv","audioMode":"none"},
 "detectedFieldOrder":"tff","inputWidth":720,"inputHeight":480,
 "inputPixelFormat":"$FMT","inputFrameRate":29.97002997,"totalFrames":$FRAMES}
JSON

runs=0; fails=0
for pass in $(seq 1 "$PASSES"); do
  for f in $(seq 0 $((FRAMES - 1))); do
    runs=$((runs + 1))
    before=$(ls "$CORES" 2>/dev/null | wc -l)
    "$WORKER" --config "$JOB" --preview --frame "$f" > "$OUT/last.png" 2> "$OUT/last.err"
    rc=$?
    if [ $rc -ne 0 ]; then
      fails=$((fails + 1))
      cp "$OUT/last.err" "$OUT/fail-$MODE-$pass-$f.err"
      echo "FAIL $MODE pass=$pass frame=$f rc=$rc: $(grep -m1 'Error generating preview' "$OUT/last.err")"
    fi
    after=$(ls "$CORES" 2>/dev/null | wc -l)
    if [ "$after" -gt "$before" ] && command -v gdb >/dev/null; then
      for core in $(ls -t "$CORES"/core.* | head -n $((after - before))); do
        [ -e "$core.bt" ] && continue
        exe=$(file "$core" | sed -n "s/.*execfn: '\([^']*\)'.*/\1/p")
        echo "== core $core ($exe) after $MODE pass=$pass frame=$f rc=$rc" > "$core.bt"
        gdb -batch -nx -ex 'info signals SIGSEGV' -ex 'thread apply all bt 40' \
          "$exe" "$core" >> "$core.bt" 2>&1
        sed -n '1,200p' "$core.bt"
      done
    fi
  done
  echo "$MODE pass $pass: runs=$runs failures=$fails"
done
echo "$MODE runs=$runs failures=$fails"
