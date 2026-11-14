#!/bin/bash
# Runs a probe script with a macOS x64 deps bundle's own Python under Rosetta,
# with the bundle's libfmtconv.dylib replaced by the one given.
#
#   ./run-with-dylib.sh <x64-bundle-dir> <libfmtconv.dylib> <probe.py> <out-file>
#
# <x64-bundle-dir> is VapourBox-deps-<v>-macos-x64.zip unzipped somewhere
# scratch: this script OVERWRITES its fmtconv, so never point it at deps/.
# Rosetta runs the AVX2 code paths, so this compares the v3 tier's code only.
set -euo pipefail
B="$(cd "$1" && pwd)"; DYLIB="$2"; PROBE="$(cd "$(dirname "$3")" && pwd)/$(basename "$3")"; OUT="$4"
cp "$DYLIB" "$B/vapoursynth/plugins/libfmtconv.dylib"
codesign -s - -f "$B/vapoursynth/plugins/libfmtconv.dylib" 2>/dev/null
mkdir -p "$B/config" "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
cd "$(dirname "$OUT")"
XDG_CONFIG_HOME="$B/config" PYTHONHOME="$B/python" DYLD_LIBRARY_PATH="$B/lib" \
  arch -x86_64 "$B/python/bin/python3" -I -c \
  'import sys; sys.path[:0]=sys.argv[1].split(":"); sys.argv=sys.argv[2:]; exec(open(sys.argv[0]).read())' \
  "$B/python-packages:$B" "$PROBE" "$OUT"
