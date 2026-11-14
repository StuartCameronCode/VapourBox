#!/bin/bash
# Builds fmtconv r31 for x86_64 the way download-deps-macos.sh now does on the
# macos-15-intel runner, but cross-compiled from an Apple Silicon Mac: the same
# tag, the same patch, the same 12.0 deployment target. Output:
# $SCRATCH/fmtconv-r31.dylib.
#
#   SCRATCH=/some/scratch/dir ./build-r31-x86_64.sh
#
# Needs autoconf, automake and libtool (Homebrew).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
S="${SCRATCH:?set SCRATCH to your scratch directory}"
mkdir -p "$S"; cd "$S"
rm -rf r31x64
git clone -q --depth 1 --branch r31 https://gitlab.com/EleonoreMizo/fmtconv.git r31x64
(cd r31x64 && git apply "$REPO/Scripts/patches/fmtconv-r31-arm-int-scaler.patch")
cd r31x64/build/unix
export MACOSX_DEPLOYMENT_TARGET=12.0
./autogen.sh
CC="clang -arch x86_64" CXX="clang++ -arch x86_64" ./configure --host=x86_64-apple-darwin
make -j"$(sysctl -n hw.ncpu)"
cp .libs/libfmtconv.dylib "$S/fmtconv-r31.dylib"
codesign -s - -f "$S/fmtconv-r31.dylib"

echo "== architecture and minimum macOS"
lipo -archs "$S/fmtconv-r31.dylib"
otool -l "$S/fmtconv-r31.dylib" | grep -A3 LC_BUILD_VERSION | grep minos
echo "== load-time SIMD gate (the v2 tier's check)"
python3 "$REPO/Scripts/check-load-time-simd.py" "$S/fmtconv-r31.dylib"
