#!/usr/bin/env bash
# The macOS measurements (task #109): the case list on the good (cb5b2ce1),
# bad (91c6af4c) and patched graphengine, natively on arm64 and as x86_64
# under Rosetta (a cross file; Rosetta runs the AVX2 kernels on macOS 15+),
# in each build mode. Usage: macos.sh WORK OUTDIR
set -euo pipefail
WORK=$1 OUT=$2
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
cat > "$OUT/x86_64.ini" <<'INI'
[binaries]
c = ['clang', '-arch', 'x86_64']
cpp = ['clang++', '-arch', 'x86_64']
ar = 'ar'
strip = 'strip'
[host_machine]
system = 'darwin'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
INI
printf 'arch\tgraphengine\tmode\tcases\toverrun\tabort\tmax_bytes\n'
for arch in arm64 x86_64; do
    margs=""
    [ "$arch" = x86_64 ] && margs="--cross-file $OUT/x86_64.ini"
    for ge in cb5b2ce1 91c6af4c 91c6af4c+patch; do
        patch=""
        [ "$ge" = 91c6af4c+patch ] && patch="$HERE/graphengine-fused-node-context.patch"
        for mode in vs guard asan; do
            b="$OUT/build-$arch-$ge-$mode"
            GE_PATCH=$patch MESON_ARGS=$margs "$HERE/build.sh" "$WORK" 67e06032 "${ge%+patch}" "$b" "$mode" >/dev/null
            opts=()
            [ "$mode" = asan ] && opts=(--exact)
            "$HERE/run_cases.sh" "$b/tmp_overrun" "$HERE/cases.tsv" ${opts[@]+"${opts[@]}"} > "$OUT/$arch-$ge-$mode.tsv"
            awk -F'\t' -v a="$arch" -v g="$ge" -v m="$mode" '
                NR > 1 { n++; if ($7 == "OVERRUN") { o++; if ($5 + 0 > mx) mx = $5 + 0 } else if ($7 ~ /^abort/) a2++ }
                END { printf "%s\t%s\t%s\t%d\t%d\t%d\t%d\n", a, g, m, n, o, a2, mx }' "$OUT/$arch-$ge-$mode.tsv"
            rm -rf "$b/src" "$b/build"
        done
    done
done
