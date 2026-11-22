#!/usr/bin/env bash
# Compare two Linux deps bundles file by file (task #103).
#
#   compare_bundles.sh <old.zip> <new.zip>
#
# Prints every file whose SHA-1 differs or that only one bundle has, then, for
# libvapoursynth.so.4 (which statically links VapourSynth's zimg), how many
# bytes differ. Fetch the zips with, for example:
#   gh release download deps-v1.18.0-rc2 -p 'VapourBox-deps-*-linux-x64.zip'
#   gh run download <build-deps-linux run> -n VapourBox-deps-<version>-linux-x64
# Unzip on a case-sensitive file system, or python/share/terminfo's
# case-colliding names show up as differences.
set -euo pipefail
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
unzip -q "$1" -d "$work/old"
unzip -q "$2" -d "$work/new"
sums() { (cd "$1" && find . -type f -exec shasum {} + | sort -k2); }
sums "$work/old" > "$work/old.sum"
sums "$work/new" > "$work/new.sum"
echo "-- files that differ"
join -1 2 -2 2 -a1 -a2 -e MISSING -o 0,1.1,2.1 "$work/old.sum" "$work/new.sum" \
    | awk '$2 != $3 { print "  " $1 ($2 == "MISSING" ? " (added)" : $3 == "MISSING" ? " (removed)" : "") }'
lib=vapoursynth/libvapoursynth.so.4
echo "-- $lib: $(cmp -l "$work/old/$lib" "$work/new/$lib" | wc -l | tr -d ' ') bytes differ"
