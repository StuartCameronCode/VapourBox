#!/usr/bin/env bash
# What VapourSynth's meson setup and the later plugin builds actually used
# (task #111), from a build-deps-* job log.
#
#   meson_lines.sh <run id> <job name substring>
#   e.g. meson_lines.sh 45908835591 'x64 (v3)'
set -euo pipefail
job=$(gh run view "$1" --json jobs -q ".jobs[] | select(.name | contains(\"$2\")) | .databaseId" | head -1)
gh run view --job "$job" --log \
    | cut -f3- | sed -E 's/^[0-9TZ:.-]+ //' \
    | grep -E 'C compiler for the host|C\+\+ compiler for the host|Cython compiler for the host|Run-time dependency (zimg|python)|Executing subproject zimg|Building zimg|VapourSynth builds with|VapourSynth links zimg|The Meson build system|^Version: 1\.|^PKG_CONFIG_PATH=|^LD_LIBRARY_PATH=|Program python3 found' \
    | uniq -c
