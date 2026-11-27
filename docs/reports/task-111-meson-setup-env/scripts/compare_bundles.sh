#!/usr/bin/env bash
# Compare two Linux deps bundles (task #111): one built from main, one from
# the task branch, dispatched at the same time so every unpinned input
# (BtbN's FFmpeg, pip's meson) is the same in both.
#
#   compare_bundles.sh <main.zip> <branch.zip>
#
# Prints:
#  - every file only one bundle has, and every file whose bytes differ;
#  - every ELF file whose NEEDED or RUNPATH entries differ;
#  - every ELF file in the branch bundle that NEEDs libzimg (expected: none);
#  - how many bytes of vapoursynth/libvapoursynth.so.4 differ, and whether its
#    exported symbols do.
# Works on macOS (Apple's objdump and nm read ELF) and Linux. Fetch the zips
# with, for example:
#   gh run download <build-deps-linux run> -n VapourBox-deps-<version>-linux-x64
# Unzip on a case-sensitive file system, or python/share/terminfo's
# case-colliding names show up as differences: on macOS, point WORKDIR at a
# case-sensitive volume (e.g. a "Case-sensitive APFS" disk image).
set -euo pipefail
work=$(mktemp -d "${WORKDIR:-${TMPDIR:-/tmp}}/compare.XXXXXX")
trap 'rm -rf "$work"' EXIT
unzip -q "$1" -d "$work/old"
unzip -q "$2" -d "$work/new"

sums() { (cd "$1" && find . -type f -exec shasum {} + | sort -k2); }
sums "$work/old" > "$work/old.sum"
sums "$work/new" > "$work/new.sum"
echo "-- files that differ"
join -1 2 -2 2 -a1 -a2 -e MISSING -o 0,1.1,2.1 "$work/old.sum" "$work/new.sum" \
    | awk '$2 != $3 { print "  " $1 ($2 == "MISSING" ? " (added)" : $3 == "MISSING" ? " (removed)" : "") }'

is_elf() { [ "$(head -c 4 "$1" | od -An -c | tr -d ' ')" = '177ELF' ]; }
dyn() { objdump -p "$1" 2>/dev/null | awk '$1 == "NEEDED" || $1 == "RUNPATH" || $1 == "RPATH" { print $1, $2 }' | sort; }

echo "-- ELF files whose NEEDED/RUNPATH differ"
(cd "$work/new" && find . -type f) | sort | while read -r f; do
    [ -f "$work/old/$f" ] || continue
    is_elf "$work/new/$f" || continue
    if ! diff <(dyn "$work/old/$f") <(dyn "$work/new/$f") > "$work/d" ; then
        echo "  $f"; sed 's/^/    /' "$work/d"
    fi
done

echo "-- ELF files in the branch bundle that NEED libzimg"
(cd "$work/new" && find . -type f) | sort | while read -r f; do
    is_elf "$work/new/$f" || continue
    dyn "$work/new/$f" | grep -q libzimg && echo "  $f"
done
echo "  (end)"

lib=vapoursynth/libvapoursynth.so.4
echo "-- $lib: $(cmp -l "$work/old/$lib" "$work/new/$lib" | wc -l | tr -d ' ') bytes differ"
syms() { nm -D --defined-only "$1" | awk '{ print $NF }' | sort; }
if diff <(syms "$work/old/$lib") <(syms "$work/new/$lib") > /dev/null; then
    echo "-- $lib: exported symbols identical ($(syms "$work/new/$lib" | wc -l | tr -d ' '))"
else
    echo "-- $lib: exported symbols DIFFER"
fi
