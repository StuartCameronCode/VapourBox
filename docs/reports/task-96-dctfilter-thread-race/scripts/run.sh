#!/bin/bash
# Usage: run.sh <deps/macos-arm64> <build.sh's out dir> <data dir>
# Writes stress.txt (aborts per build and shape) and same_output.txt.
set -uo pipefail
DEPS="$1"; B="$2"; DATA="$3"
HERE="$(cd "$(dirname "$0")" && pwd)"
VSPIPE="$DEPS/vapoursynth/vspipe"
mkdir -p "$DATA"
trial() {  # <label> <runs> <script> <env...>
    local label="$1" runs="$2" script="$3"; shift 3
    local fail=0 sig=""
    for _ in $(seq 1 "$runs"); do
        if ! out=$(env "$@" timeout 120 "$VSPIPE" "$HERE/$script" /dev/null 2>&1); then
            fail=$((fail + 1))
            sig=$(printf '%s\n' "$out" | grep -m1 -E 'terminat|out_of_range' || true)
        fi
    done
    printf '%-58s %4d / %-4d %s\n' "$label" "$fail" "$runs" "$sig" | tee -a "$DATA/stress.txt"
}
: > "$DATA/stress.txt"
echo "# build, shape: aborted runs / runs (first abort message)" >> "$DATA/stress.txt"
trial "bundle dctf, fresh process, 96x64" 200 fresh_process.vpy NS=dctf
trial "r2, fresh process, 96x64" 200 fresh_process.vpy NS=dctr2 LIB="$B/libdctr2.dylib"
trial "r2, fresh process, 720x480, 10 frames" 200 fresh_process.vpy NS=dctr2 LIB="$B/libdctr2.dylib" W=720 H=480 N=10
trial "r3.2 + patch, fresh process, 96x64" 300 fresh_process.vpy NS=dctnew LIB="$B/libdctnew.dylib"
trial "bundle dctf, 1000 instances" 20 many_instances.vpy NS=dctf
trial "r2, 1000 instances" 20 many_instances.vpy NS=dctr2 LIB="$B/libdctr2.dylib"
trial "r3.2 + patch, 1000 instances" 20 many_instances.vpy NS=dctnew LIB="$B/libdctnew.dylib"
: > "$DATA/same_output.txt"
for v in "bundle dctf:NS=dctf" "r2:NS=dctr2 LIB=$B/libdctr2.dylib" "r3.2 + patch:NS=dctnew LIB=$B/libdctnew.dylib"; do
    for i in 1 2 3; do
        h=$(env ${v#*:} "$VSPIPE" "$HERE/same_output.vpy" - 2>/dev/null | md5 -q)
        printf '%-14s process %d  %s\n' "${v%%:*}" "$i" "$h" | tee -a "$DATA/same_output.txt"
    done
done
