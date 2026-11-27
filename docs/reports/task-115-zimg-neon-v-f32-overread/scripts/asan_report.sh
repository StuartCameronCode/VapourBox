#!/usr/bin/env bash
# Task #115: on linux-arm64, gcc 13's AddressSanitizer reports a
# heap-buffer-overflow in 32 of task #109's 158 cases (every 4:2:0 conversion
# with a vertical float resize of 4 or fewer taps), at every graphengine
# commit. Is it the harness, zimg, or the compiler? Run on an aarch64 Linux
# machine (zimg-neon-asan.yml runs it on ubuntu-24.04-arm).
#
# Usage: asan_report.sh WORK OUT
#   WORK  clones of zimg, graphengine and VapourSynth (task #109's fetch.sh)
#   OUT   results; summary.tsv is the table the report quotes
#
# Every build is task #109's build.sh: zimg compiled as VapourSynth R78
# compiles it (R78's meson overlay, static, release, NDEBUG), run through
# tmp_overrun.c over task #109's cases.tsv, one process per case.
#   asan-gcc            gcc 13 ASan, -g, zimg 67e06032 / graphengine cb5b2ce1
#   asan-gcc-pad        the same, every frame plane allocated 4096 bytes larger
#   asan-gcc-patched    the same build with zimg-neon-v-f32-taps.patch
#   asan-clang          clang 18 ASan, unpatched
#   vs-gcc / -patched   gcc 13 as VapourSynth builds it (no sanitizer): the
#                       destination planes' CRC per case, both builds; the
#                       float vertical kernels' disassembly; valgrind memcheck
#   master-asan-gcc / -patched   zimg 9806db42 / graphengine 308d3735
# The CC/CXX environment is ignored; gcc-13/g++-13 and clang-18/clang++-18 are
# named here.
set -uo pipefail
WORK=$1 OUT=$2
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(cd "$HERE/../../task-109-graphengine-tmp-overrun/scripts" && pwd)
CASES=$T/cases.tsv
PATCH=$HERE/zimg-neon-v-f32-taps.patch
B=$OUT/builds
mkdir -p "$OUT" "$B"

ZIMG=67e06032 GE=cb5b2ce1
MZIMG=9806db42 MGE=308d3735
if command -v llvm-symbolizer-18 >/dev/null; then
    export ASAN_SYMBOLIZER_PATH=$(command -v llvm-symbolizer-18)
fi
export ASAN_OPTIONS=detect_leaks=0:abort_on_error=1:symbolize=1

# build LABEL ZIMG GE MODE CC CXX PATCHED(0|1)
build() {
    local label=$1 z=$2 g=$3 mode=$4 cc=$5 cxx=$6 patched=$7 margs=""
    [ "$mode" = asan ] && margs="-Ddebug=true"
    if [ "$patched" = 1 ]; then
        ZIMG_PATCH=$PATCH CC=$cc CXX=$cxx MESON_ARGS=$margs bash "$T/build.sh" "$WORK" "$z" "$g" "$B/$label" "$mode"
    else
        CC=$cc CXX=$cxx MESON_ARGS=$margs bash "$T/build.sh" "$WORK" "$z" "$g" "$B/$label" "$mode"
    fi
}

# Per aborted case: what ASan said, from its kept stderr.
frames() {
    local dir=$1
    printf 'case\taccess\tsize\tplace\tregion\tframe0\tallocated_in\n'
    for f in "$dir"/*.err; do
        [ -e "$f" ] || continue
        local name access size place region frame0 alloc
        name=$(basename "$f" .err)
        access=$(grep -m1 -oE '(READ|WRITE) of size [0-9]+' "$f" | awk '{print $1}')
        size=$(grep -m1 -oE '(READ|WRITE) of size [0-9]+' "$f" | awk '{print $4}')
        place=$(grep -m1 -oE '[0-9]+ bytes (to the right|to the left|inside) of' "$f" | sed 's/ of$//')
        region=$(grep -m1 -oE '[0-9]+-byte region' "$f" | cut -d- -f1)
        frame0=$(grep -m1 -E '^ *#0 ' "$f" | sed -E 's/^ *#0 0x[0-9a-f]+ in //; s/ \/.*$//; s/\(float const\*.*$//' | cut -c1-120)
        alloc=$(sed -n '/allocated by thread/,/^$/p' "$f" | grep -m1 -E 'zimg::' | sed -E 's/^ *#[0-9]+ 0x[0-9a-f]+ in //; s/\(.*$//' | cut -c1-120)
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "${access:--}" "${size:--}" "${place:--}" "${region:--}" "${frame0:--}" "${alloc:--}"
    done
}

# run LABEL BUILD [tmp_overrun options...]: all cases, aborted stderr kept.
run() {
    local label=$1 build=$2
    shift 2
    if [ ! -x "$B/$build/tmp_overrun" ]; then
        printf '%s\tbuild-failed\n' "$label" >> "$OUT/summary.tsv"
        return
    fi
    KEEP_ERR=$OUT/err/$label bash "$T/run_cases.sh" "$B/$build/tmp_overrun" "$CASES" "$@" > "$OUT/$label.tsv"
    frames "$OUT/err/$label" > "$OUT/$label.frames.tsv"
    local n a v
    n=$(awk 'NR>1' "$OUT/$label.tsv" | wc -l)
    a=$(awk -F'\t' 'NR>1 && $7 ~ /^abort/' "$OUT/$label.tsv" | wc -l)
    v=$(awk -F'\t' 'NR>1 && $6 ~ /resize_line_v_f32_neon/' "$OUT/$label.frames.tsv" | wc -l)
    printf '%s\t%s\t%s\t%s\t%s\n' "$label" "$n" "$a" "$v" "$*" >> "$OUT/summary.tsv"
}

printf 'run\tcases\taborts\taborts_in_resize_line_v_f32_neon\toptions\n' > "$OUT/summary.tsv"
{
    uname -a
    grep -m1 -iE 'model name|CPU part' /proc/cpuinfo || true
    gcc-13 --version | head -1
    clang-18 --version | head -1
    ldd --version | head -1
} > "$OUT/environment.txt" 2>&1

build asan-gcc "$ZIMG" "$GE" asan gcc-13 g++-13 0
build asan-gcc-patched "$ZIMG" "$GE" asan gcc-13 g++-13 1
build asan-clang "$ZIMG" "$GE" asan clang-18 clang++-18 0
build vs-gcc "$ZIMG" "$GE" vs gcc-13 g++-13 0
build vs-gcc-patched "$ZIMG" "$GE" vs gcc-13 g++-13 1
build master-asan-gcc "$MZIMG" "$MGE" asan gcc-13 g++-13 0
build master-asan-gcc-patched "$MZIMG" "$MGE" asan gcc-13 g++-13 1

run asan-gcc asan-gcc --exact
run asan-gcc-pad asan-gcc --exact --pad 4096
run asan-gcc-patched asan-gcc-patched --exact
run asan-clang asan-clang --exact
run master-asan-gcc master-asan-gcc --exact
run master-asan-gcc-patched master-asan-gcc-patched --exact

# Two cases' full reports, for the report.
for c in swatch-yuv420p8 cs-to-rgbs-yuv420p8-96x64p; do
    cp "$OUT/err/asan-gcc/$c.err" "$OUT/report-$c.txt" 2>/dev/null || echo "no report for $c" > "$OUT/report-$c.txt"
done

# Does the patch change a pixel? Destination CRCs, built as VapourSynth does.
run vs-gcc vs-gcc --exact --crc
run vs-gcc-patched vs-gcc-patched --exact --crc
if [ -f "$OUT/vs-gcc.tsv" ] && [ -f "$OUT/vs-gcc-patched.tsv" ]; then
    paste <(cut -f1,8 "$OUT/vs-gcc.tsv") <(cut -f8 "$OUT/vs-gcc-patched.tsv") |
        awk -F'\t' 'NR>1{n++; if($2==$3 && $2!="-")s++; else d=d" "$1} END{printf "crc\t%d cases, %d identical, different:%s\n", n, s, d}' \
        > "$OUT/crc.txt"
    cat "$OUT/crc.txt"
fi

# The coefficient loads in the shipped-style build: the 1- and 4-tap kernels,
# whole, and the loads that address filter_data (x0, the first argument).
printf 'build\tkernel\tinstructions\tloads_from_x0\n' > "$OUT/disasm.tsv"
for b in vs-gcc vs-gcc-patched asan-clang; do
    [ -x "$B/$b/tmp_overrun" ] || continue
    for k in '1u, false' '4u, false'; do
        tag=$(printf '%s' "$k" | tr -dc '0-9a-z')
        objdump -d --no-show-raw-insn -C "$B/$b/tmp_overrun" |
            awk -v k="resize_line_v_f32_neon<$k>" 'index($0, k) && /:$/ {f=1} f && /^$/ {exit} f' > "$OUT/disasm-$b-$tag.txt"
        ni=$(grep -cE '^ +[0-9a-f]+:' "$OUT/disasm-$b-$tag.txt")
        nl=$(grep -cE '\b(ld[0-9a-z]*|ldr|ldp|ldur)\b.*\[x0(,|\])' "$OUT/disasm-$b-$tag.txt")
        printf '%s\t%s\t%s\t%s\n' "$b" "$k" "$ni" "$nl" >> "$OUT/disasm.tsv"
    done
done

# valgrind memcheck on the shipped-style builds: invalid reads per case, and
# whether the first one is in the float vertical kernel.
printf 'build\tcase\tinvalid_reads\tinvalid_writes\tfirst_read_in\tfirst_read_where\n' > "$OUT/valgrind.tsv"
mkdir -p "$OUT/vg"
for b in vs-gcc vs-gcc-patched; do
    [ -x "$B/$b/tmp_overrun" ] || continue
    tr -d '\r' < "$CASES" | while IFS=$'\t' read -r name src ss dst ds filt dith field; do
        case "$name" in ''|'#'*) continue ;; esac
        log=$OUT/vg/$b-$name.txt
        valgrind --num-callers=12 "$B/$b/tmp_overrun" --exact - "$name" "$src" "$ss" "$dst" "$ds" "$filt" "$dith" "$field" \
            >/dev/null 2>"$log"
        r=$(grep -c 'Invalid read' "$log")
        w=$(grep -c 'Invalid write' "$log")
        fn=$(grep -A3 -m1 'Invalid read' "$log" | grep -m1 -oE 'resize_line_v_f32_neon<[^>]*>' | head -1)
        [ -z "$fn" ] && [ "$r" -gt 0 ] && fn=other
        where=$(grep -m1 -oE '[0-9]+ bytes after a block of size [0-9]+' "$log")
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$b" "$name" "$r" "$w" "${fn:--}" "${where:--}" >> "$OUT/valgrind.tsv"
        # Keep only the logs with something in them.
        [ "$r$w" = 00 ] && rm -f "$log"
    done
done
awk -F'\t' 'NR>1{c[$1]++; if($3>0)r[$1]++; if($4>0)w[$1]++} END{for(b in c) printf "valgrind\t%s\t%d cases, %d with invalid reads, %d with invalid writes\n", b, c[b], r[b], w[b]}' \
    "$OUT/valgrind.tsv" | sort | tee "$OUT/valgrind-summary.txt"

cat "$OUT/summary.tsv"
cat "$OUT/disasm.tsv"
