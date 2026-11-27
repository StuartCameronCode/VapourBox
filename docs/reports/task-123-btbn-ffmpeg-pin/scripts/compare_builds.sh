#!/bin/bash
# compare_builds.sh <ffmpeg A> <dir from fixture.sh with A> <dir from fixture.sh with B>
# Whether task #123's 4:2:0 fixture is the same, frame for frame, from two builds.
set -euo pipefail
F=$1
a=$("$F" -v error -i "$2/new_yuv420p.mkv" -f framemd5 - | grep -v '^#')
b=$("$F" -v error -i "$3/new_yuv420p.mkv" -f framemd5 - | grep -v '^#')
[ "$a" = "$b" ] && echo "new 4:2:0 fixture: identical" || echo "new 4:2:0 fixture: DIFFERENT"
