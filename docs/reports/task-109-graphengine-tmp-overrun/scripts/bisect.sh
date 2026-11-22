#!/usr/bin/env bash
# Every graphengine commit from cb5b2ce1 (what zimg 67e06032 pins) to
# 91c6af4c (what zimg e2e43d09 pins), plus graphengine HEAD, each built into
# zimg 67e06032 with R78's overlay (build.sh) and run over cases.tsv
# (run_cases.sh). One TSV row per commit and build mode. (task #109)
#
# Usage: bisect.sh WORK OUTDIR [MODES]   MODES default "vs guard"
# Writes OUTDIR/<commit>-<mode>.tsv (per case) and prints the summary:
# commit, date, mode, cases, overruns (canary past the end), aborts
# (assertion / ASan / glibc), largest overrun in bytes, subject.
set -euo pipefail
WORK=$1 OUT=$2 MODES=${3:-vs guard}
HERE=$(cd "$(dirname "$0")" && pwd)
ZIMG_GOOD=67e0603271c080e22c8429856dd4a8a56587e61e
GE_GOOD=cb5b2ce13384ec2491f0c37256ea210034799f69
GE_BAD=91c6af4c

mkdir -p "$OUT"
COMMITS=$(echo "$GE_GOOD"; git -C "$WORK/graphengine" rev-list --reverse "$GE_GOOD..$GE_BAD"; git -C "$WORK/graphengine" rev-parse origin/HEAD)
printf 'commit\tdate\tmode\tcases\toverrun\tabort\tmax_bytes\tsubject\n'
for c in $COMMITS; do
    short=${c:0:8}
    date=$(git -C "$WORK/graphengine" log -1 --format=%cs "$c")
    subj=$(git -C "$WORK/graphengine" log -1 --format=%s "$c")
    for mode in $MODES; do
        bdir="$OUT/build-$short-$mode"
        if ! "$HERE/build.sh" "$WORK" "$ZIMG_GOOD" "$c" "$bdir" "$mode" >"$OUT/$short-$mode.build.log" 2>&1; then
            printf '%s\t%s\t%s\t-\t-\t-\t-\t%s (does not build)\n' "$short" "$date" "$mode" "$subj"
            continue
        fi
        rm -f "$OUT/$short-$mode.build.log"   # kept only when the build fails
        opts=()
        [ "$mode" = asan ] && opts=(--exact)
        "$HERE/run_cases.sh" "$bdir/tmp_overrun" "$HERE/cases.tsv" ${opts[@]+"${opts[@]}"} >"$OUT/$short-$mode.tsv"
        awk -F'\t' -v c="$short" -v d="$date" -v m="$mode" -v s="$subj" '
            NR > 1 { n++; if ($7 == "OVERRUN") { o++; if ($5 + 0 > mx) mx = $5 + 0 } else if ($7 ~ /^abort/) a++ }
            END { printf "%s\t%s\t%s\t%d\t%d\t%d\t%d\t%s\n", c, d, m, n, o, a, mx, s }' "$OUT/$short-$mode.tsv"
        rm -rf "$bdir/src" "$bdir/build"
    done
done
