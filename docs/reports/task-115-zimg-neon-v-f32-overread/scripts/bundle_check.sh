#!/usr/bin/env bash
# Is the shipped linux-arm64 bundle affected (task #115)? Run bundle_repro.vpy
# through the bundle's own vspipe under valgrind memcheck, single-threaded:
# the float vertical resize's coefficient over-read is a read past a heap
# block, which memcheck reports whether or not the compiler kept the load
# that ASan saw. Task #109's vs_confirm.sh sets the bundle up the same way.
#
# Usage: bundle_check.sh DEPS_DIR OUTDIR
#   DEPS_DIR  an extracted linux-arm64 bundle (deps/linux-arm64)
# Prints: kind, size, exit status, invalid reads, invalid reads in
# libvapoursynth.so, the first one's "N bytes after a block of size M".
set -uo pipefail
D=$1 OUT=$2
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"

export PYTHONHOME=$D/python PYTHONPATH=$D:$D/python-packages PYTHONNOUSERSITE=1
export XDG_CONFIG_HOME=$D/config PATH=$D/python/bin:$D/vapoursynth:$PATH
export LD_LIBRARY_PATH=$D/vapoursynth:$D/python/lib:$D/lib
VSPIPE=$D/vapoursynth/vspipe
REAL=$D/vapoursynth/vspipe-bin
VG=$D/vapoursynth/vspipe.vg
sed "s|^exec \"\$SCRIPT_DIR/vspipe-bin\" \"\$@\"\$|exec valgrind --num-callers=20 \"$REAL\" \"\$@\"|" \
    "$VSPIPE" > "$VG"
chmod +x "$VG"
grep -q valgrind "$VG" || { echo "could not make a valgrind vspipe from $VSPIPE" >&2; exit 2; }

printf 'kind\tsize\texit\tinvalid_reads\tin_libvapoursynth\tfirst_read\n'
for kind in up down; do
    for size in 4x4 96x64 720x480; do
        log=$OUT/$kind-$size.vg
        rc=0
        PYTHONMALLOC=malloc timeout 1800 "$VG" -a kind="$kind" -a size="$size" -a frames=2 -a threads=1 \
            "$HERE/bundle_repro.vpy" - >/dev/null 2>"$log" || rc=$?
        reads=$(grep -c 'Invalid read' "$log")
        inlib=$(grep -A2 'Invalid read' "$log" | grep -c 'libvapoursynth')
        first=$(grep -m1 -oE '[0-9]+ bytes after a block of size [0-9]+' "$log")
        grep -q '^bundle_repro:' "$log" || rc="$rc/no-run"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$size" "$rc" "$reads" "$inlib" "${first:--}"
    done
done
