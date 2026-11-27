#!/bin/bash
# fixture.sh <ffmpeg> <Tests/TestResources/interlaced_test.avi> <out dir>
# The field-order test's D1 fixture, the old recipe (convert field by field at
# 486) and task #123's (at 488, then crop to 486), in 4:2:0 and 4:2:2.
# Prints each command's exit status, the output geometry, and whether the 4:2:2
# fixtures are the same frame for frame.
set -uo pipefail
F=$1; SRC=$2; O=$3
mkdir -p "$O"
old() { "$F" -hide_banner -v error -y -i "$SRC" \
  -vf "setpts=PTS-STARTPTS,fps=25,crop=720:486:0:44,scale=interl=1,format=$1" \
  -frames:v 10 -c:v ffv1 -an "$O/old_$1.mkv"; }
new() { "$F" -hide_banner -v error -y -i "$SRC" \
  -vf "setpts=PTS-STARTPTS,fps=25,crop=720:488:0:44,scale=interl=1,format=$1,crop=720:486:0:0" \
  -frames:v 10 -c:v ffv1 -an "$O/new_$1.mkv"; }
for pf in yuv420p yuv422p; do
  old $pf 2> "$O/old_$pf.err"; echo "old $pf: exit $? $(head -1 "$O/old_$pf.err")"
  new $pf 2> "$O/new_$pf.err"; echo "new $pf: exit $? $(head -1 "$O/new_$pf.err")"
done
for f in "$O"/new_*.mkv; do
  echo "$(basename "$f"): $("$(dirname "$F")/ffprobe" -v error -show_entries stream=width,height,pix_fmt -of csv=p=0 "$f")"
done
a=$("$F" -v error -i "$O/old_yuv422p.mkv" -f framemd5 - | grep -v '^#')
b=$("$F" -v error -i "$O/new_yuv422p.mkv" -f framemd5 - | grep -v '^#')
[ "$a" = "$b" ] && echo "4:2:2: old and new identical (framemd5)" || echo "4:2:2: DIFFERENT"
