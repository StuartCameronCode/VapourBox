#!/bin/bash
# macOS only. Builds libretinex.dylib twice, as download-deps-macos.sh's meson
# build does (clang++ -O3 -DNDEBUG, C++14, hidden visibility, minos 15.0):
#   fixed: 6bfbdd42 + patches/retinex-6bfbdd4-vapourbox-marker.patch
#   r4:    the r4 tag (f7abea51), unpatched
# and makes two copies of a deps bundle with each one in place of its
# libretinex (APFS clones), $SCRATCH/deps-fixed and $SCRATCH/deps-r4.
#   SCRATCH=<dir> build_retinex.sh <deps dir>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
: "${SCRATCH:?set SCRATCH to a scratch directory}"
D="$(cd "$1" && pwd)"
W="$SCRATCH/retinex-build"
rm -rf "$W"; mkdir -p "$W/vsinc/vapoursynth"
for h in VapourSynth.h VSHelper.h; do
    curl -sSfL -o "$W/vsinc/vapoursynth/$h" "https://raw.githubusercontent.com/vapoursynth/vapoursynth/R78/include/$h"
done
git clone -q https://github.com/HomeOfVapourSynthEvolution/VapourSynth-Retinex.git "$W/src"
build() {  # <ref> <out> [patch]
    git -C "$W/src" -c advice.detachedHead=false checkout -q -f "$1"
    [ -z "${3:-}" ] || git -C "$W/src" apply "$3"
    clang++ -std=c++14 -O3 -DNDEBUG -fPIC -fvisibility=hidden -mmacosx-version-min=15.0 \
        -I"$W/src/include" -I"$W/vsinc" -shared "$W"/src/source/*.cpp -o "$2"
    codesign -s - -f "$2" 2>/dev/null
}
build 6bfbdd429159c85075dc4b08e0ac4e706470916b "$W/libretinex-fixed.dylib" \
    "$REPO/Scripts/patches/retinex-6bfbdd4-vapourbox-marker.patch"
build f7abea517b0fbc9a2bbd065f01cdbf0ab7fa8e41 "$W/libretinex-r4.dylib"   # tag r4
for v in fixed r4; do
    rm -rf "$SCRATCH/deps-$v"; cp -cR "$D" "$SCRATCH/deps-$v"
    cp "$W/libretinex-$v.dylib" "$SCRATCH/deps-$v/vapoursynth/plugins/libretinex.dylib"
done
echo "built $SCRATCH/deps-fixed and $SCRATCH/deps-r4"
