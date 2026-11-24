#!/usr/bin/env bash
# Build tmp_overrun.c against zimg ZIMG_REV with graphengine GE_REV, compiled
# the way VapourSynth R78 compiles its zimg subproject: R78's own
# subprojects/packagefiles/zimg/meson.build overlaid on the zimg tree (its
# file list, -DZIMG_GRAPHENGINE_API, cpp_std=c++17, the AVX2/AVX-512 kernel
# libraries), a static library, release build. (task #109)
#
# Usage: build.sh WORK ZIMG_REV GE_REV OUT [MODE]
#   WORK     a directory holding clones zimg/, graphengine/, vapoursynth/
#            (fetch.sh makes them)
#   OUT      build directory; the binary is OUT/tmp_overrun
#   MODE     vs     (default) as VapourSynth R78 builds it: b_ndebug=if-release,
#                   so NDEBUG is set and graphengine's guard pages are off
#            guard  NDEBUG unset: graphengine puts guard pages between the
#                   regions of the tmp buffer and asserts on them (state.h)
#            asan   as vs, plus -fsanitize=address (for --exact runs)
# CC / CXX choose the compiler (default: the system's cc / c++).
# GE_PATCH=<file> applies a patch to graphengine first (-p1), e.g.
# graphengine-fused-node-context.patch. MESON_ARGS adds meson setup arguments
# (macos.sh passes a cross file for x86_64 under Rosetta).
set -euo pipefail

WORK=$1 ZIMG_REV=$2 GE_REV=$3 OUT=$4 MODE=${5:-vs}
HERE=$(cd "$(dirname "$0")" && pwd)
VS_REV=${VS_REV:-R78}

rm -rf "$OUT"
mkdir -p "$OUT/src/subprojects"
ZT="$OUT/src/subprojects/zimg"

# zimg at ZIMG_REV, with graphengine at GE_REV in place of its submodule.
git -C "$WORK/zimg" archive --format=tar --prefix=zimg/ "$ZIMG_REV" | tar -x -C "$OUT/src/subprojects"
rm -rf "$ZT/graphengine"
git -C "$WORK/graphengine" archive --format=tar --prefix=graphengine/ "$GE_REV" | tar -x -C "$ZT"
if [ -n "${GE_PATCH:-}" ]; then
    patch -s -p1 -d "$ZT/graphengine" < "$GE_PATCH"
fi
git -C "$WORK/vapoursynth" show "$VS_REV:subprojects/packagefiles/zimg/meson.build" > "$ZT/meson.build"

cp "$HERE/tmp_overrun.c" "$OUT/src/"
cat > "$OUT/src/meson.build" <<'EOF'
project('tmp_overrun', 'c', 'cpp', default_options: ['buildtype=release', 'c_std=c11'])
zimg_dep = subproject('zimg').get_variable('zimg_dep')
executable('tmp_overrun', 'tmp_overrun.c', dependencies: zimg_dep, link_language: 'cpp')
EOF

case "$MODE" in
    vs)    SAN=(-Db_ndebug=true) ;;
    guard) SAN=(-Db_ndebug=false) ;;
    asan)  SAN=(-Db_ndebug=true -Db_sanitize=address -Db_lundef=false) ;;
    *)     echo "unknown mode $MODE" >&2; exit 2 ;;
esac
# shellcheck disable=SC2086
meson setup "$OUT/build" "$OUT/src" "${SAN[@]}" ${MESON_ARGS:-} >"$OUT/setup.log" 2>&1 || { tail -30 "$OUT/setup.log"; exit 1; }
ninja -C "$OUT/build" >"$OUT/build.log" 2>&1 || { tail -40 "$OUT/build.log"; exit 1; }
cp "$OUT/build/tmp_overrun" "$OUT/tmp_overrun"
echo "built $OUT/tmp_overrun (zimg ${ZIMG_REV:0:8}, graphengine ${GE_REV:0:8}${GE_PATCH:+ + $(basename "$GE_PATCH")}, $MODE)"
