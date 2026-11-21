#!/bin/bash
# The macOS x64 builds under Rosetta: each plugin's output with the old
# bundle's build (Stefan-Olt's) and the patched one, then DFTTest ten times
# each, since its output depends on the process (FFTW_PATIENT, task #101).
# Usage: x64_parity.sh <x64 bundle> <patched copy (build_task98.sh x86_64)> <data dir>
set -uo pipefail
OLD="$1"; NEW="$2"; DATA="$3"
HERE="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
out="$DATA/macos-x64-rosetta.txt"
# One output's md5. An old build can abort here too (the race this task
# fixes): each abort is printed as "aborted" and the run repeated.
render() {  # <plugin> <deps>
    local i
    for i in 1 2 3 4 5; do
        if P=$1 "$2/vapoursynth/vspipe" "$HERE/same_output.vpy" "$tmp/o.raw" >/dev/null 2>&1; then
            md5 -q "$tmp/o.raw"
            return
        fi
        echo aborted
    done
}
: > "$out"
for p in dfttest lghost ctmf tcanny; do
    for b in "old:$OLD" "patched:$NEW"; do
        printf '%-8s %-8s %s\n' "$p" "${b%%:*}" "$(render $p "${b#*:}" | tr '\n' ' ')" | tee -a "$out"
    done
done
echo "# DFTTest, 10 fresh processes per build (aborts listed and repeated): count, md5" | tee -a "$out"
for b in "old:$OLD" "patched:$NEW"; do
    for _ in $(seq 1 10); do
        render dfttest "${b#*:}"
    done | sort | uniq -c | sed "s/^/${b%%:*} /" | tee -a "$out"
done
rm -rf "$tmp"
