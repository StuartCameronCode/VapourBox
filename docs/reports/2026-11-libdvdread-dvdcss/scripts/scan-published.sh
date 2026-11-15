#!/bin/bash
# Fetch libdvdread out of every published deps bundle of a version (range
# reads, a few MB in all) and print what it depends on. Then, for the whole
# macOS arm64 and linux-x64 bundles, run the repository's checkers (needs the
# full zips: ~140 MB and ~240 MB). Run from the repository root.
set -euo pipefail
VERSION="${1:-1.16.0}"
OUT="${OUT:-$(pwd)/deps-scan-$VERSION}"
BASE="https://github.com/StuartCameronCode/VapourBox/releases/download/deps-v$VERSION"
HERE="$(dirname "$0")"
mkdir -p "$OUT"
for p in macos-arm64 macos-x64 linux-x64 linux-arm64 windows-x64; do
    mkdir -p "$OUT/$p"
    python3 -I "$HERE/fetch-zip-members.py" "$BASE/VapourBox-deps-$VERSION-$p.zip" '^lib/(lib)?dvdread' "$OUT/$p"
done
for f in "$OUT"/macos-*/*.dylib; do echo "== $f"; otool -L "$f" | tail -n +2; otool -l "$f" | grep -A3 LC_BUILD_VERSION | grep minos; done
for f in "$OUT"/linux-*/*libdvdread.so; do
    echo "== $f"; python3 -I - "$f" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("c", "Scripts/check-elf-refs.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.dynamic_entries(sys.argv[1]))
PY
done
for f in "$OUT"/windows-*/*.dll; do echo "== $f"; python3 -I "$HERE/pe-imports.py" "$f"; done

if [ "${FULL:-0}" = 1 ]; then
    for p in macos-arm64 linux-x64; do
        curl -fsSL "$BASE/VapourBox-deps-$VERSION-$p.zip" -o "$OUT/$p.zip"
        rm -rf "$OUT/$p-tree" && mkdir "$OUT/$p-tree" && unzip -q "$OUT/$p.zip" -d "$OUT/$p-tree"
    done
    python3 -I Scripts/check-macho-refs.py "$OUT/macos-arm64-tree" || true
    python3 -I Scripts/check-elf-refs.py "$OUT/linux-x64-tree" || true
fi
