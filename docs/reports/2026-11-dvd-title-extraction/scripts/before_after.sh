#!/bin/bash
# Extract every title and chapter range of the dvd_titles fixture with a given
# worker and print, per case: blocks written, decoded frames, and the run of
# colours those frames show (R red, B blue, gNN grey of level NN, ? other).
#
# Usage: WORKER=<path to vapourbox-worker> SCRATCH=<dir> ./before_after.sh
#   WORKER   defaults to the repo's worker/target/debug/vapourbox-worker
#            (build main's worker in a second worktree for the "before" rows)
#   SCRATCH  defaults to a new mktemp directory
# Needs ffmpeg/ffprobe on PATH and libdvdread where the worker finds it.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
WORKER="${WORKER:-$REPO/worker/target/debug/vapourbox-worker}"
SCRATCH="${SCRATCH:-$(mktemp -d)}"
FIXTURE="$REPO/Tests/TestResources/dvd_titles"

shades() {
    ffmpeg -v error -i "$1" -map 0:v:0 -vf scale=1:1,format=rgb24 -f rawvideo - |
        python3 -I -c '
import sys
d = sys.stdin.buffer.read()
runs = []
for i in range(0, len(d), 3):
    r, g, b = d[i:i + 3]
    if r > 150 and g < 90 and b < 90: s = "R"
    elif b > 150 and r < 90 and g < 90: s = "B"
    elif abs(r - g) < 12 and abs(g - b) < 12: s = "g%d" % (round(g / 60) * 60)
    else: s = "?"
    if runs and runs[-1][0] == s: runs[-1][1] += 1
    else: runs.append([s, 1])
print(" ".join("%s x%d" % (s, n) for s, n in runs))'
}

printf '%-26s %8s %7s  %s\n' case blocks frames pictures
for args in "--title 1" "--title 2" "--title 2 --chapters 2-3" "--title 2 --chapters 2" "--title 3" "--title 2 --chapters 2-5"; do
    out="$SCRATCH/out.mpg"
    rm -f "$out"
    # shellcheck disable=SC2086
    if "$WORKER" --dvd-extract "$FIXTURE" $args --output "$out" >"$SCRATCH/log" 2>&1; then
        blocks=$(( $(wc -c <"$out") / 2048 ))
        frames="$(ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 "$out" | cut -d, -f1)"
        printf '%-26s %8s %7s  %s\n' "$args" "$blocks" "$frames" "$(shades "$out")"
    else
        printf '%-26s %8s %7s  %s\n' "$args" - - "refused: $(grep -o '"message":"[^"]*"' "$SCRATCH/log" | tail -1)"
    fi
done
