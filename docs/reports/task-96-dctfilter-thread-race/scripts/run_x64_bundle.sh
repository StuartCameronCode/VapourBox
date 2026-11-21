#!/bin/bash
# The shipped macOS x64 DCTFilter (Stefan-Olt's r2.1, in every macos-x64 deps
# bundle up to 1.18.0-rc2) under Rosetta on Apple Silicon: the race in the real
# binary, and whether its FFTW_PATIENT plans give one picture across processes.
# Usage: run_x64_bundle.sh <an unzipped macos-x64 deps bundle> <data dir>
set -uo pipefail
X="$1"; DATA="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$DATA"
{
    echo "# bundle: $(cat "$X/version.json" | tr -d '\n ')"
    fail=0
    for _ in $(seq 1 20); do
        NS=dctf arch -x86_64 "$X/vapoursynth/vspipe" "$HERE/many_instances.vpy" /dev/null >/dev/null 2>&1 || fail=$((fail + 1))
    done
    echo "r2.1 (bundle), 1000 instances: $fail / 20 aborted"
    echo "# same_output.vpy in 12 fresh processes: count, md5"
    for _ in $(seq 1 12); do
        NS=dctf arch -x86_64 "$X/vapoursynth/vspipe" "$HERE/same_output.vpy" - 2>/dev/null | md5 -q
    done | sort | uniq -c
} | tee "$DATA/macos-x64-rosetta.txt"
