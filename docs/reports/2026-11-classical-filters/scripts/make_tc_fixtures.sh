#!/bin/bash
# Hard-telecined MPEG-2 fixtures for mpeg2stinx, from make_fixtures.sh's pans:
# 24 pan frames as 24p, 3:2 pulldown to 30i (TFF), then interlaced MPEG-2
# (interlaced DCT + motion estimation, as a film DVD is) at starved bitrates.
# This is the material mpeg2stinx is written for; ports_compare.py
# inverse-telecines it with VIVTC (as the IVTC method does) and compares with
# the 24 clean frames.
set -e
S="${SCRATCH:?set SCRATCH to your scratch directory}"
FF="${FFMPEG:-ffmpeg} -v error -y"
for k in 08 23; do
  $FF -i "$S/fx/kodim${k}_pan.mkv" -vf "select=lt(n\,24),setpts=N/24/TB,telecine=first_field=t:pattern=23" \
      -r 30 -c:v ffv1 "$S/fx/kodim${k}_tc.mkv"
  for r in 1000 2000; do
    $FF -i "$S/fx/kodim${k}_tc.mkv" -vf setfield=tff -c:v mpeg2video -flags +ildct+ilme \
        -g 12 -bf 2 -b:v ${r}k -maxrate ${r}k -bufsize $((r * 2))k "$S/fx/kodim${k}_tc_${r}.m2v"
    $FF -i "$S/fx/kodim${k}_tc_${r}.m2v" -c:v ffv1 "$S/fx/kodim${k}_tc_${r}.mkv"
  done
done
ls -la "$S/fx" | grep _tc
