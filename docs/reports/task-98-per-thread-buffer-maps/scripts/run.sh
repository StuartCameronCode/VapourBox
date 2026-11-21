#!/bin/bash
# Usage: run.sh <unpatched deps/macos-arm64> <patched copy of it> <data dir>
# The patched copy is the first with build_task98.sh's plugins dropped in.
# Writes stress.txt (aborted runs per bundle and shape) and same_output.txt.
set -uo pipefail
OLD="$1"; NEW="$2"; DATA="$3"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$DATA"
trial() {  # <label> <deps> <runs> <env...>
    local label="$1" deps="$2" runs="$3"; shift 3
    local fail=0 sig=""
    for _ in $(seq 1 "$runs"); do
        if ! out=$(env "$@" timeout 300 "$deps/vapoursynth/vspipe" "$HERE/many_instances.vpy" /dev/null 2>&1); then
            fail=$((fail + 1))
            [ -n "$sig" ] || sig=$(printf '%s\n' "$out" | grep -m1 -E 'terminat|out_of_range|Error' || true)
        fi
    done
    printf '%-52s %4d / %-4d %s\n' "$label" "$fail" "$runs" "$sig" | tee -a "$DATA/stress.txt"
}
: > "$DATA/stress.txt"
echo "# bundle, plugin, shape: aborted runs / runs (first abort message)" >> "$DATA/stress.txt"
for b in "unpatched:$OLD" "patched:$NEW"; do
    name="${b%%:*}"; deps="${b#*:}"
    runs=20; [ "$name" = patched ] && runs=40
    trial "$name dfttest, 1000 instances" "$deps" "$runs" P=dfttest
    trial "$name lghost, 1000 instances" "$deps" "$runs" P=lghost
    trial "$name ctmf radius 3, 1000 instances" "$deps" "$runs" P=ctmf
    trial "$name tcanny, 1000 instances" "$deps" "$runs" P=tcanny
    trial "$name eedi3m, 1000 instances" "$deps" 10 P=eedi3
    trial "$name dfttest, 1 instance, 40 frames" "$deps" 200 P=dfttest INST=1 N=40
    trial "$name ctmf radius 3, 1 instance, 40 frames" "$deps" 200 P=ctmf INST=1 N=40
    trial "$name tcanny, 1 instance, 40 frames" "$deps" 200 P=tcanny INST=1 N=40
done
: > "$DATA/same_output.txt"
tmp="$(mktemp -d)"
for p in dfttest lghost ctmf tcanny eedi3; do
    for b in "unpatched:$OLD" "patched:$NEW"; do
        for i in 1 2; do
            P=$p "${b#*:}/vapoursynth/vspipe" "$HERE/same_output.vpy" "$tmp/out.raw" >/dev/null 2>&1
            printf '%-8s %-10s process %d  %s\n' "$p" "${b%%:*}" "$i" "$(md5 -q "$tmp/out.raw")" \
                | tee -a "$DATA/same_output.txt"
        done
    done
done
rm -rf "$tmp"
