#!/usr/bin/env bash
# Run every case of CASES.tsv through BIN, one process per case, so a case
# that aborts (an assertion, ASan, glibc) is recorded and the rest still run.
# (task #109)
#
# Usage: run_cases.sh BIN CASES.tsv [tmp_overrun options...] > results.tsv
# Prints tmp_overrun's columns; a case whose process died gets status
# "abort:<exit status>" and the first line of its stderr in a last column.
# With --digest (task #126) a digest column comes before that last column,
# and with --crc (task #115) a crc column after the digest. KEEP_ERR=<dir>
# keeps each aborted case's whole stderr as <dir>/<case>.err (task #115).
set -euo pipefail
# A leak report at exit is not what this measures. ASan aborts on an error,
# as it does by default on macOS (on Linux it exits 1, which reads as a
# canary overrun).
export ASAN_OPTIONS=${ASAN_OPTIONS:-detect_leaks=0:abort_on_error=1}
BIN=$1 CASES=$2
shift 2
CPU=auto64
DIGEST= CRC=
prev=
for a in "$@"; do [ "$prev" = --cpu ] && CPU=$a; [ "$a" = --digest ] && DIGEST=1; [ "$a" = --crc ] && CRC=1; prev=$a; done
printf 'case\tcpu\ttmp_size\ttail_changed\ttail_max\thead_changed\tstatus\t%b%bdetail\n' "${DIGEST:+digest\t}" "${CRC:+crc\t}"
ERR=$(mktemp)
trap 'rm -f "$ERR"' EXIT
tr -d '\r' < "$CASES" | while IFS=$'\t' read -r name src ss dst ds filt dith field; do
    case "$name" in ''|'#'*) continue ;; esac
    rc=0
    out=$("$BIN" "$@" - "$name" "$src" "$ss" "$dst" "$ds" "$filt" "$dith" "$field" 2>"$ERR" | tail -n +2) || rc=$?
    if [ "$rc" -gt 1 ]; then
        detail=$(grep -m1 -E 'Assertion|ERROR: AddressSanitizer|double free|corrupt|malloc|free\(\)' "$ERR" || head -1 "$ERR")
        if [ -n "${KEEP_ERR:-}" ]; then mkdir -p "$KEEP_ERR"; cp "$ERR" "$KEEP_ERR/$name.err"; fi
        printf '%s\t%s\t-\t-\t-\t-\tabort:%s\t%b%b%s\n' "$name" "$CPU" "$rc" "${DIGEST:+-\t}" "${CRC:+-\t}" "$(printf '%s' "$detail" | tr '\t' ' ' | cut -c1-200)"
    else
        printf '%s\t\n' "$out"
    fi
done
