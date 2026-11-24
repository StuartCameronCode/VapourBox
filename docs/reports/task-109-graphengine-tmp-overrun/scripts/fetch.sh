#!/usr/bin/env bash
# Clone zimg, graphengine and VapourSynth (for R78's zimg overlay) into WORK.
# Usage: fetch.sh WORK   (task #109)
set -euo pipefail
WORK=$1
mkdir -p "$WORK"
for repo in sekrit-twc/zimg sekrit-twc/graphengine vapoursynth/vapoursynth; do
    dir="$WORK/${repo#*/}"
    if [ -d "$dir/.git" ]; then
        git -C "$dir" fetch -q --tags origin
    else
        git clone -q "https://github.com/$repo.git" "$dir"
    fi
done
