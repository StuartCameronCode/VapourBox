#!/bin/bash
# Build libdvdread 6.1.3 stock and patched (the way download-deps-macos.sh
# does: --without-libdvdcss, minos 15.0) and show which libdvdcss each one
# loads. Run from the repository root on an Apple Silicon Mac with
# `brew install libdvdcss`. Writes into $WORK (default ./libdvdread-probe).
set -euo pipefail
ROOT="$(pwd)"
WORK="${WORK:-$ROOT/libdvdread-probe}"
FIXTURE="$ROOT/Tests/TestResources/dvd_titles"
PATCH="$ROOT/Scripts/patches/libdvdread-6.1.3-macos-dvdcss-paths.patch"
mkdir -p "$WORK" && cd "$WORK"
[ -f dvdread.tar.bz2 ] || curl -fsSL https://download.videolan.org/pub/videolan/libdvdread/6.1.3/libdvdread-6.1.3.tar.bz2 -o dvdread.tar.bz2

build() {  # build NAME [patch]
    rm -rf "$1" && mkdir "$1" && tar xjf dvdread.tar.bz2 -C "$1"
    ( cd "$1/libdvdread-6.1.3"
      [ "${2:-}" = patch ] && patch -p1 --forward < "$PATCH"
      ./configure --prefix="$WORK/$1/inst" --enable-shared --disable-static --without-libdvdcss -q \
          CFLAGS="-O2 -mmacosx-version-min=15.0" LDFLAGS="-mmacosx-version-min=15.0"
      make -j"$(sysctl -n hw.ncpu)" >/dev/null && make install >/dev/null )
}
build stock
build patched patch
cc -o harness "$ROOT/docs/reports/2026-11-libdvdread-dvdcss/scripts/dlopen-harness.c"

for b in stock patched; do
    echo "== $b: load commands"
    otool -L "$b/inst/lib/libdvdread.dylib" | tail -n +2
    echo "== $b: run"
    DYLD_PRINT_LIBRARIES=1 ./harness "$b/inst/lib/libdvdread.dylib" "$FIXTURE" 2>&1 | grep -E 'dvdcss|DVDOpen|Encrypted|leaf' || true
done
echo "== stock with DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib"
DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib DYLD_PRINT_LIBRARIES=1 \
    ./harness stock/inst/lib/libdvdread.dylib "$FIXTURE" 2>&1 | grep -E 'dvdcss|DVDOpen|Encrypted|leaf' || true
