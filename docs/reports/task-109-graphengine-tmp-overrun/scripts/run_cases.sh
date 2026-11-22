#!/usr/bin/env bash
# Run every case of CASES.tsv through BIN, one process per case, so a case
# that aborts (an assertion, ASan, glibc) is recorded and the rest still run.
# (task #109)
#
# Usage: run_cases.sh BIN CASES.tsv [tmp_overrun options...] > results.tsv
# Prints tmp_overrun's columns; a case whose process died gets status
# "abort:<exit status>" and the first line of its stderr in a last column.
set -euo pipefail
# A leak report at exit is not what this measures.
export ASAN_OPTIONS=${ASAN_OPTIONS:-detect_leaks=0}
BIN=$1 CASES=$2
shift 2
CPU=auto64
prev=
for a in "$@"; do [ "$prev" = --cpu ] && CPU=$a; prev=$a; done
printf 'case\tcpu\ttmp_size\ttail_changed\ttail_max\thead_changed\tstatus\tdetail\n'
ERR=$(mktemp)
trap 'rm -f "$ERR"' EXIT
tr -d '\r' < "$CASES" | while IFS=$'\t' read -r name src ss dst ds filt dith field; do
    case "$name" in ''|'#'*) continue ;; esac
    rc=0
    out=$("$BIN" "$@" - "$name" "$src" "$ss" "$dst" "$ds" "$filt" "$dith" "$field" 2>"$ERR" | tail -n +2) || rc=$?
    if [ "$rc" -gt 1 ]; then
        detail=$(grep -m1 -E 'Assertion|ERROR: AddressSanitizer|double free|corrupt|malloc|free\(\)' "$ERR" || head -1 "$ERR")
        printf '%s\t%s\t-\t-\t-\t-\tabort:%s\t%s\n' "$name" "$CPU" "$rc" "$(printf '%s' "$detail" | tr '\t' ' ' | cut -c1-200)"
    else
        printf '%s\t\n' "$out"
    fi
done
