#!/usr/bin/env bash
# Task #126: is zimg 9806db42 (graphengine 308d3735, upstream's fix for task
# #109's overrun) safe to pin in place of 67e06032 (graphengine cb5b2ce1)?
#
# Builds both with task #109's build.sh, the way VapourSynth R78 builds its
# zimg subproject, in three modes, and runs task #109's 158 cases (36 with
# error diffusion) through each:
#   vs     VapourSynth's build (NDEBUG): the guard-byte canary, plus --digest,
#          once with --cpu auto64 (VapourSynth's default) and once with
#          --cpu none (the C kernels)
#   guard  graphengine's guard pages and assertions (NDEBUG off)
#   asan   AddressSanitizer on a buffer of exactly tmp_size (--exact)
# then upstream_repro.c (#109's minimal repro) against each.
#
# Usage: compare.sh WORK OUTDIR
#   WORK    clones made by task #109's fetch.sh
#   OUTDIR  per-case TSVs (<build>-<mode>[-<cpu>].tsv) and the summaries:
#           summary.tsv  build, mode, cpu, cases, overruns, aborts,
#                        error-diffusion aborts, largest overrun in bytes
#           compare.tsv  per cpu: cases, same digest, different digest,
#                        either side not run, and tmp_size smaller / equal /
#                        larger in B
#           digest-diff.tsv  the cases whose digests differ (empty if none)
#           repro.tsv    upstream_repro.c's line (tmp_size, bytes past it)
# CC / CXX choose the compiler, MESON_ARGS is passed to build.sh (a cross
# file), as for task #109's scripts; REPRO_CFLAGS goes to the compiler that
# builds upstream_repro.c (macos.sh's x86_64 run passes -arch x86_64).
set -euo pipefail
WORK=$1 OUT=$2
HERE=$(cd "$(dirname "$0")" && pwd)
R109=$(cd "$HERE/../../task-109-graphengine-tmp-overrun/scripts" && pwd)
CASES=$R109/cases.tsv
mkdir -p "$OUT"

# label zimg graphengine
BUILDS="A 67e0603271c080e22c8429856dd4a8a56587e61e cb5b2ce13384ec2491f0c37256ea210034799f69
B 9806db428022893543121c94c7069263cd92a71a 308d3735b05d99a1d792b82351be71b8ffc9a46b"

# The submodule pointer is what a recursive clone of the wrap checks out.
while read -r label zimg ge; do
    got=$(git -C "$WORK/zimg" ls-tree "$zimg" graphengine | awk '{print $3}')
    [ "$got" = "$ge" ] || { echo "zimg ${zimg:0:8} pins graphengine $got, not $ge" >&2; exit 1; }
done <<< "$BUILDS"

# Case names whose dither is error_diffusion.
ED=$(tr -d '\r' < "$CASES" | awk -F'\t' '$1 !~ /^#/ && $7 == "error_diffusion" {print $1}' | sort)
printf '%s\n' "$ED" > "$OUT/error-diffusion-cases.txt"

summarise() { # label mode cpu tsv
    awk -F'\t' -v b="$1" -v m="$2" -v c="$3" -v edf="$OUT/error-diffusion-cases.txt" '
        BEGIN { while ((getline l < edf) > 0) ed[l] = 1 }
        NR > 1 { n++
                 if ($7 == "OVERRUN") { o++; if ($5 + 0 > mx) mx = $5 + 0 }
                 else if ($7 ~ /^abort/) { a++; if ($1 in ed) ea++ } }
        END { printf "%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\n", b, m, c, n, o, a, ea, mx }' "$4"
}

printf 'build\tmode\tcpu\tcases\toverrun\tabort\ted_abort\tmax_bytes\n' > "$OUT/summary.tsv"
printf 'build\tresult\n' > "$OUT/repro.tsv"
while read -r label zimg ge; do
    for mode in vs guard asan; do
        b="$OUT/build-$label-$mode"
        "$R109/build.sh" "$WORK" "$zimg" "$ge" "$b" "$mode" >/dev/null
        # A binary this machine can't run (x86_64 without Rosetta) would read
        # as 158 aborts; stop instead. With no arguments it prints its usage.
        rc=0; "$b/tmp_overrun" >/dev/null 2>&1 || rc=$?
        [ "$rc" -eq 2 ] || { echo "$b/tmp_overrun does not run here (exit $rc)" >&2; exit 1; }
        case $mode in
            vs)
                for cpu in auto64 none; do
                    t="$OUT/$label-vs-$cpu.tsv"
                    "$R109/run_cases.sh" "$b/tmp_overrun" "$CASES" --digest --cpu "$cpu" > "$t"
                    summarise "$label" vs "$cpu" "$t" | tee -a "$OUT/summary.tsv"
                done
                # upstream_repro.c against the same static libraries.
                # GNU ld resolves archives in order, so they are listed twice;
                # Apple's ld needs (and warns about) only one copy.
                libs=$(find "$b/build/subprojects/zimg" -name '*.a' | sort)
                [ "$(uname)" = Darwin ] || libs="$libs $libs"
                # shellcheck disable=SC2086
                ${CXX:-c++} ${REPRO_CFLAGS:-} -O1 -x c "$R109/upstream_repro.c" -x none \
                    -I"$b/src/subprojects/zimg/src/zimg/api" $libs -o "$b/upstream_repro"
                printf '%s\t%s\n' "$label" "$("$b/upstream_repro" 2>&1 || true)" >> "$OUT/repro.tsv"
                ;;
            guard)
                t="$OUT/$label-guard.tsv"
                "$R109/run_cases.sh" "$b/tmp_overrun" "$CASES" > "$t"
                summarise "$label" guard auto64 "$t" | tee -a "$OUT/summary.tsv"
                ;;
            asan)
                t="$OUT/$label-asan.tsv"
                "$R109/run_cases.sh" "$b/tmp_overrun" "$CASES" --exact > "$t"
                summarise "$label" asan auto64 "$t" | tee -a "$OUT/summary.tsv"
                ;;
        esac
        rm -rf "$b/src" "$b/build"
    done
done <<< "$BUILDS"

# A against B, case by case: digest (column 8) and tmp_size (column 3).
printf 'cpu\tcases\tsame_digest\tdiff_digest\tnot_run\ttmp_smaller\ttmp_equal\ttmp_larger\n' > "$OUT/compare.tsv"
printf 'cpu\tcase\tA_tmp\tB_tmp\tA_digest\tB_digest\n' > "$OUT/digest-diff.tsv"
for cpu in auto64 none; do
    awk -F'\t' -v cpu="$cpu" -v diff="$OUT/digest-diff.tsv" '
        FNR == 1 { next }
        FILENAME ~ /\/A-vs-/ { ad[$1] = $8; at[$1] = $3; next }
        { n++
          if (!($1 in ad) || ad[$1] !~ /^[0-9a-f]+$/ || $8 !~ /^[0-9a-f]+$/) nr++
          else if (ad[$1] == $8) same++
          else { d++; printf "%s\t%s\t%s\t%s\t%s\t%s\n", cpu, $1, at[$1], $3, ad[$1], $8 >> diff }
          if (at[$1] ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/) {
              if ($3 + 0 < at[$1] + 0) sm++; else if ($3 + 0 == at[$1] + 0) eq++; else lg++ } }
        END { printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", cpu, n, same, d, nr, sm, eq, lg }' \
        "$OUT/A-vs-$cpu.tsv" "$OUT/B-vs-$cpu.tsv" | tee -a "$OUT/compare.tsv"
done
echo "== upstream_repro"
cat "$OUT/repro.tsv"
