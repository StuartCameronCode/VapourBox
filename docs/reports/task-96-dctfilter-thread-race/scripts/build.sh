#!/bin/bash
# Builds three DCTFilter variants for macOS against a deps bundle's FFTW, each
# under its own namespace so it loads beside the bundle's own dctf:
#   dctr2  - tag r2 (API 3): the Windows release's code, and r2.1's
#   dctnew - tag r3.2 + Scripts/patches/dctfilter-r3.2-thread-safety.patch
#   libdctfilter.dylib (namespace dctf) - r2, to drop into a copy of a bundle
# Usage: build.sh <deps/macos-arm64> <out dir>
# Needs git, a C++ compiler and FFTW's header (Homebrew fftw).
set -euo pipefail
DEPS="$1"; OUT="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
mkdir -p "$OUT/vsinc" "$OUT/src"
for h in VapourSynth.h VSHelper.h VapourSynth4.h VSHelper4.h VSConstants4.h; do
    curl -sfL -o "$OUT/vsinc/$h" "https://raw.githubusercontent.com/vapoursynth/vapoursynth/R78/include/$h"
done
rm -rf "$OUT/src/dctf"
git clone -q https://github.com/HomeOfVapourSynthEvolution/VapourSynth-DCTFilter.git "$OUT/src/dctf"
FFTW_INC="$(brew --prefix fftw)/include"
build() {  # <source file> <namespace> <output>
    sed "s/\"com.holywu.dctfilter\", \"dctf\"/\"com.test.$2\", \"$2\"/" "$1" > "$OUT/$2.cpp"
    c++ -std=c++17 -O2 -shared -fPIC -I"$OUT/vsinc" -I"$FFTW_INC" "$OUT/$2.cpp" \
        "$DEPS/lib/libfftw3f.3.dylib" -o "$3" -Wno-deprecated-declarations
    for ref in $(otool -L "$3" | awk 'NR > 1 && /libfftw3f/ {print $1}'); do
        install_name_tool -change "$ref" "$DEPS/lib/libfftw3f.3.dylib" "$3"
    done
    codesign -s - -f "$3" 2>/dev/null || true
}
(cd "$OUT/src/dctf" && git show r2:DCTFilter/DCTFilter.cpp) > "$OUT/r2.cpp"
build "$OUT/r2.cpp" dctr2 "$OUT/libdctr2.dylib"
rm -rf "$OUT/src/r32" && git clone -q --depth 1 --branch r3.2 \
    https://github.com/HomeOfVapourSynthEvolution/VapourSynth-DCTFilter.git "$OUT/src/r32"
(cd "$OUT/src/r32" && git apply "$REPO/Scripts/patches/dctfilter-r3.2-thread-safety.patch")
build "$OUT/src/r32/DCTFilter/DCTFilter.cpp" dctnew "$OUT/libdctnew.dylib"
# r2 with its own namespace (dctf), for dropping into a copy of the bundle.
c++ -std=c++17 -O2 -shared -fPIC -I"$OUT/vsinc" -I"$FFTW_INC" "$OUT/r2.cpp" \
    "$DEPS/lib/libfftw3f.3.dylib" -o "$OUT/libdctfilter.dylib" -Wno-deprecated-declarations
codesign -s - -f "$OUT/libdctfilter.dylib" 2>/dev/null || true
echo "built: $OUT/libdctr2.dylib $OUT/libdctnew.dylib $OUT/libdctfilter.dylib"
