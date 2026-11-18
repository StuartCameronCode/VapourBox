#!/usr/bin/env bash
# Task #68: make vspipe R78's teardown race fire on demand, then show the
# patch removes it. macOS or Linux, run from the repository root:
#
#   widened_race_ab.sh <deps-dir> <out-dir> [runs]
#
# Clones VapourSynth R78, and builds vspipe twice against <deps-dir>'s
# libvsscript, both with widen_race.py's test-only sleeps (20 ms before
# outputFrame writes, 5 ms between outputNode's requests and its wait check):
#
#   unpatched  R78 as released
#   patched    R78 + patches/vapoursynth-r78-vspipe-frame-done-count.patch
#
# Each runs trigger.vpy [runs] times (default 200) as 4 concurrent loops,
# beside the bundle's own vspipe-bin (the bundle's wrapper sets the
# environment; only the binary it executes differs). Writes
# <out-dir>/summary.txt. The bundle's vspipe-bin is left untouched.
set -eu
DEPS="$(cd "$1" && pwd)"; OUT="$2"; RUNS="${3:-200}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(pwd)"
VS="$DEPS/vapoursynth"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
SRC="$OUT/vapoursynth-R78"
[ -d "$SRC" ] || git clone -q --depth 1 --branch R78 https://github.com/vapoursynth/vapoursynth.git "$SRC"

case "$(uname -s)" in
  Darwin) LIB="$VS/libvsscript.dylib"; EXTRA=(-mmacosx-version-min=15.0 -DVS_TARGET_OS_DARWIN) ;;
  *)      LIB="$(ls "$VS"/libvsscript.so* | head -1)"; EXTRA=(-DVS_TARGET_OS_LINUX -Wl,-rpath,'$ORIGIN') ;;
esac

build() { # <name> <yes|no: apply the patch>
  git -C "$SRC" checkout -q -- .
  if [ "$2" = yes ]; then git -C "$SRC" apply "$ROOT/Scripts/patches/vapoursynth-r78-vspipe-frame-done-count.patch"; fi
  python3 "$HERE/widen_race.py" "$SRC/src/vspipe/vspipe.cpp"
  c++ -std=c++20 -O2 -fno-char8_t "${EXTRA[@]}" -DVS_GRAPH_API -DVS_USE_LATEST_API \
    -DVSSCRIPT_USE_LATEST_API -DVS_CURRENT_RELEASE=78 -DNOMINMAX -I"$SRC/include" \
    "$SRC/src/vspipe/vspipe.cpp" "$SRC/src/vspipe/vsjson.cpp" "$SRC/src/vspipe/printgraph.cpp" \
    "$SRC/src/common/wave.cpp" "$LIB" -lpthread -o "$VS/vspipe-bin-$1"
  if [ "$(uname -s)" = Darwin ]; then
    install_name_tool -change "$(otool -L "$VS/vspipe-bin-$1" | sed -n 2p | awk '{print $1}')" \
      @loader_path/libvsscript.dylib "$VS/vspipe-bin-$1"
    codesign -s - -f "$VS/vspipe-bin-$1" >/dev/null 2>&1
  fi
  sed "s#/vspipe-bin\"#/vspipe-bin-$1\"#" "$VS/vspipe" > "$VS/vspipe-$1"
  chmod +x "$VS/vspipe-$1"
  git -C "$SRC" checkout -q -- .
}
cleanup() { rm -f "$VS"/vspipe-bin-widened-* "$VS"/vspipe-widened-*; }
trap cleanup EXIT

build widened-unpatched no
build widened-patched yes
: > "$OUT/summary.txt"
for side in widened-unpatched widened-patched; do
  pids=()
  for k in 1 2 3 4; do
    bash "$HERE/vspipe_loop.sh" "$VS/vspipe-$side" "$HERE/trigger.vpy" $((RUNS / 4)) > "$OUT/$side-$k.log" 2>&1 &
    pids+=($!)
  done
  wait "${pids[@]}" || true
  runs=0; fails=0
  for k in 1 2 3 4; do
    line=$(tail -n1 "$OUT/$side-$k.log")
    r=$(echo "$line" | sed -n 's/.*runs=\([0-9]*\).*/\1/p'); f=$(echo "$line" | sed -n 's/.*failures=\([0-9]*\).*/\1/p')
    runs=$((runs + ${r:-0})); fails=$((fails + ${f:-0}))
  done
  statuses=$(cat "$OUT/$side"-*.log | sed -n 's/^FAIL rc=\([0-9]*\).*/\1/p' | sort | uniq -c | awk '{printf "%s x rc=%s; ", $1, $2}')
  echo "$side: runs=$runs failures=$fails ${statuses:+($statuses)}" | tee -a "$OUT/summary.txt"
done
