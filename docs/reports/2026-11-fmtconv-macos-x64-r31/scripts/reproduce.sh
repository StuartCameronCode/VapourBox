#!/bin/bash
# Reproduces every number in ../index.html.
#
#   SCRATCH=/some/scratch/dir ./reproduce.sh
#
# Downloads the published deps-v1.16.0 macos-x64 bundle (~250 MB) into
# $SCRATCH, builds r31 for x86_64 (build-r31-x86_64.sh), then runs the probes
# with each fmtconv. Needs an Apple Silicon Mac with Rosetta, gh, and Homebrew's
# autoconf/automake/libtool. With $ARM64_DEPS set to a macos-arm64 deps bundle
# it also runs the fingerprint natively against that bundle's r31.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
S="${SCRATCH:?set SCRATCH to your scratch directory}"
mkdir -p "$S/dl" "$S/out"
if [ ! -d "$S/x64" ]; then
  gh release download deps-v1.16.0 -R StuartCameronCode/VapourBox \
    -p 'VapourBox-deps-1.16.0-macos-x64.zip' -D "$S/dl" --clobber
  mkdir -p "$S/x64"; unzip -q "$S/dl/VapourBox-deps-1.16.0-macos-x64.zip" -d "$S/x64"
fi
SHIPPED="$S/fmtconv-18a9cecb.dylib"
[ -f "$SHIPPED" ] || cp "$S/x64/vapoursynth/plugins/libfmtconv.dylib" "$SHIPPED"
echo "== what 1.16.0 macos-x64 ships"
shasum -a 256 "$SHIPPED"
otool -l "$SHIPPED" | grep -A3 -E 'LC_VERSION_MIN_MACOSX|LC_BUILD_VERSION' | grep -E 'version|minos'
python3 "$(cd "$HERE/../../../.." && pwd)/Scripts/check-load-time-simd.py" "$SHIPPED"

[ -f "$S/fmtconv-r31.dylib" ] || SCRATCH="$S" "$HERE/build-r31-x86_64.sh"

for d in 18a9cecb r31; do
  echo "== fingerprint, $d (x86_64 under Rosetta)"
  "$HERE/run-with-dylib.sh" "$S/x64" "$S/fmtconv-$d.dylib" "$HERE/fingerprint.py" "$S/out/fp-$d.txt"
done
if [ -n "${ARM64_DEPS:-}" ]; then
  echo "== fingerprint, macos-arm64 bundle (native)"
  XDG_CONFIG_HOME="$ARM64_DEPS/config" PYTHONHOME="$ARM64_DEPS/python" DYLD_LIBRARY_PATH="$ARM64_DEPS/lib" \
    "$ARM64_DEPS/python/bin/python3" -I -c \
    'import sys; sys.path[:0]=sys.argv[1].split(":"); sys.argv=sys.argv[2:]; exec(open(sys.argv[0]).read())' \
    "$ARM64_DEPS/python-packages:$ARM64_DEPS" "$HERE/fingerprint.py" "$S/out/fp-arm64.txt"
fi

echo "== 62 equality cases (several minutes each)"
"$HERE/run-with-dylib.sh" "$S/x64" "$S/fmtconv-18a9cecb.dylib" "$HERE/probe.py" "$S/out/old.json"
"$HERE/run-with-dylib.sh" "$S/x64" "$S/fmtconv-r31.dylib"      "$HERE/probe.py" "$S/out/r31.json"
"$HERE/run-with-dylib.sh" "$S/x64" "$S/fmtconv-18a9cecb.dylib" "$HERE/probe.py" "$S/out/old2.json"
python3 "$HERE/compare.py" "$S/out/old.json" "$S/out/r31.json" "$S/out/old2.json"

echo "== QTGMC Placebo on one thread, twice per build (should all agree)"
for run in a b; do for d in 18a9cecb r31; do
  "$HERE/run-with-dylib.sh" "$S/x64" "$S/fmtconv-$d.dylib" "$HERE/placebo_1thread.py" "$S/out/p1-$d-$run.json"
done; done
