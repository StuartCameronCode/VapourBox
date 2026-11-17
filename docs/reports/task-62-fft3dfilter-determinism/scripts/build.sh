#!/bin/bash
# Build FFT3DFilter R2 twice, unpatched and with
# Scripts/patches/fft3dfilter-r2-determinism.patch, under renamed namespaces
# (core.fft3dorig, core.fft3dfixed) so both load next to the bundle's own
# core.fft3dfilter. Same flags as download-deps-macos.sh's build.
#
#   build.sh <deps dir> <out dir>
# macOS only (links the bundle's lib/libfftw3f*.3.dylib); FFTW's header comes
# from Homebrew (`brew install fftw`).
set -euo pipefail
DEPS="$1"; OUT="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
VS_INC="$OUT/vsinc"
mkdir -p "$OUT" "$VS_INC"
for h in VapourSynth4.h VSHelper4.h VSConstants4.h; do
    [ -f "$VS_INC/$h" ] || curl -fsSL "https://raw.githubusercontent.com/vapoursynth/vapoursynth/R78/include/$h" -o "$VS_INC/$h"
done
[ -d "$OUT/src" ] || git clone -q --depth 1 --branch R2 https://github.com/myrsloik/VapourSynth-FFT3DFilter.git "$OUT/src"
for kind in orig fixed; do
    d="$OUT/$kind"
    rm -rf "$d"; mkdir -p "$d"
    cp "$OUT"/src/*.cpp "$OUT"/src/*.h "$d/"
    [ "$kind" = fixed ] && (cd "$d" && patch -p1 -s < "$REPO/Scripts/patches/fft3dfilter-r2-determinism.patch")
    sed -i '' "s/\"systems.innocent.fft3dfilter\", \"fft3dfilter\"/\"systems.innocent.fft3d$kind\", \"fft3d$kind\"/" "$d/Plugin.cpp"
    grep -q "fft3d$kind\"" "$d/Plugin.cpp"
    c++ -std=c++17 -O3 -fPIC -fvisibility=hidden -dynamiclib \
        -I"$VS_INC" -I"$(brew --prefix fftw)/include" \
        "$d"/FFT3DFilter.cpp "$d"/FFT3DFilterTransform.cpp "$d"/fft3dfilter_c.cpp "$d"/Plugin.cpp \
        "$DEPS/lib/libfftw3f.3.dylib" "$DEPS/lib/libfftw3f_threads.3.dylib" \
        -headerpad_max_install_names -o "$d/libfft3d_$kind.dylib"
    for ref in $(otool -L "$d/libfft3d_$kind.dylib" | awk 'NR > 1 && /libfftw3f/ {print $1}'); do
        install_name_tool -change "$ref" "$DEPS/lib/$(basename "$ref")" "$d/libfft3d_$kind.dylib"
    done
    codesign -s - -f "$d/libfft3d_$kind.dylib" 2>/dev/null
    echo "built $d/libfft3d_$kind.dylib"
done
