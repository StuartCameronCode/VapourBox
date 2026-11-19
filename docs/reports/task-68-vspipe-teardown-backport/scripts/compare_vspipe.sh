#!/usr/bin/env bash
# Task #68: R78's vspipe against the patched one, in the SAME deps bundle.
# Run from the repository root after `cd worker && cargo build`:
#
#   compare_vspipe.sh <deps-dir> <patched-vspipe> <template-ref> <out-dir>
#
# <deps-dir>        a published bundle (e.g. 1.17.0-rc3), unpatched as installed
# <patched-vspipe>  the vspipe binary from a bundle built with
#                   patches/vapoursynth-r78-vspipe-frame-done-count.patch
#                   (vspipe-bin on macOS/Linux, vspipe.exe on Windows)
# <template-ref>    a commit whose pipeline_template.vpy the worker previews
#                   with; the trigger is task #46's IVTC preview, which reads a
#                   frame while the script is evaluated (main before task #65,
#                   f3706092^1)
#
# Only the vspipe binary differs between the two sides: it is copied over the
# bundle's own before each side runs, and the bundle's is put back after.
# Each mode runs as 4 concurrent loops while stress-ng (or, without it, busy
# loops on half the cores) holds the CPUs busy, as in task #65:
#
#   trigger    vspipe directly on scripts/trigger.vpy (one frame, ready at once)
#   ivtc       the worker's IVTC preview of the ProRes telecine fixture
#   bwdif      the same fixture through Bwdif (no evaluation-time read)
#
# RUNS (trigger runs per loop, default 500) and PASSES (preview passes over the
# 30-frame fixture per loop, default 5) set the counts. Writes
# <out-dir>/summary.txt.
set -u
DEPS="$1"; PATCHED="$2"; REF="$3"; OUT="$4"
HERE="$(cd "$(dirname "$0")" && pwd)"
RUNS="${RUNS:-500}"; PASSES="${PASSES:-5}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"; DEPS="$(cd "$DEPS" && pwd)"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    WIN=1
    VSDIR="$DEPS/vapoursynth"
    BIN="$VSDIR/Lib/site-packages/vapoursynth/vspipe.exe"
    # What the worker sets (DependencyLocator), for running vspipe directly.
    export PYTHONNOUSERSITE=1 PYTHONHOME="$(cygpath -w "$VSDIR")"
    export PYTHONPATH="$(cygpath -w "$VSDIR/Lib/site-packages")"
    export VAPOURSYNTH_EXTRA_PLUGIN_PATH="$(cygpath -w "$VSDIR/vs-plugins")"
    export PATH="$DEPS/ffmpeg:$VSDIR:$PATH"
    VSPIPE="$BIN"; WORKER=worker/target/debug/vapourbox-worker.exe ;;
  *)
    WIN=0
    BIN="$DEPS/vapoursynth/vspipe-bin"
    VSPIPE="$DEPS/vapoursynth/vspipe"; WORKER=worker/target/debug/vapourbox-worker ;;
esac
[ -f "$BIN" ] || { echo "no vspipe binary at $BIN" >&2; exit 2; }

ORIG="$OUT/vspipe-unpatched.bin"
cp "$BIN" "$ORIG"
restore() { cp "$ORIG" "$BIN"; }
trap restore EXIT

# The worker side: a copy of the debug worker with <template-ref>'s template
# beside it (the worker searches exe_dir/templates first).
WB="$OUT/worker"
rm -rf "$WB"; mkdir -p "$WB"
cp "$WORKER" "$WB/"
cp -R worker/templates "$WB/templates"
git show "$REF:worker/templates/pipeline_template.vpy" > "$WB/templates/pipeline_template.vpy"
WEXE="$WB/$(basename "$WORKER")"

CPUS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo "${NUMBER_OF_PROCESSORS:-4}")
LOAD=()
if command -v stress-ng >/dev/null; then
  stress-ng --cpu "$CPUS" --cpu-load 60 --timeout 0 >/dev/null 2>&1 & LOAD+=($!)
else
  for i in $(seq 1 $(( (CPUS + 1) / 2 ))); do ( while :; do :; done ) & LOAD+=($!); done
fi

for side in unpatched patched; do
  if [ "$side" = patched ]; then cp "$PATCHED" "$BIN"; else cp "$ORIG" "$BIN"; fi
  chmod +x "$BIN"
  [ "$(uname -s)" = Darwin ] && codesign -s - -f "$BIN" >/dev/null 2>&1
  "$VSPIPE" --version | sed "s/^/[$side] /" | tail -n 2
  for mode in trigger ivtc bwdif; do
    pids=()
    for k in 1 2 3 4; do
      log="$OUT/$side-$mode-$k.log"
      if [ "$mode" = trigger ]; then
        bash "$HERE/vspipe_loop.sh" "$VSPIPE" "$HERE/trigger.vpy" "$RUNS" > "$log" 2>&1 &
      else
        bash "$HERE/preview_loop.sh" "$WEXE" "$mode" "$PASSES" "$OUT/$side-$mode-$k" > "$log" 2>&1 &
      fi
      pids+=($!)
    done
    wait "${pids[@]}"
    runs=0; fails=0
    for k in 1 2 3 4; do
      line=$(tail -n1 "$OUT/$side-$mode-$k.log")
      r=$(echo "$line" | sed -n 's/.*runs=\([0-9]*\).*/\1/p'); f=$(echo "$line" | sed -n 's/.*failures=\([0-9]*\).*/\1/p')
      runs=$((runs + ${r:-0})); fails=$((fails + ${f:-0}))
      grep '^FAIL' "$OUT/$side-$mode-$k.log" | head -3
    done
    echo "$side $mode (4 loops, CPU load): runs=$runs failures=$fails" | tee -a "$OUT/summary.txt"
  done
done
for p in "${LOAD[@]}"; do kill "$p" 2>/dev/null; done
cat "$OUT/summary.txt"
