#!/bin/bash
# Builds the clean fixtures for the noise-reduction comparison into $SCRATCH/fx.
#
# Three Kodak PhotoCD images (kodim08 buildings, kodim19 fence/lighthouse,
# kodim23 parrots: real detail, flat sky, fine texture), each panned by a
# 640x480 window two pixels per frame for 30 frames. A whole-pixel pan keeps
# every frame a clean crop of the original — the temporal methods get true
# motion to track and the ground truth stays exact. Stored as lossless FFV1,
# 4:2:0 8-bit.
#
# The Kodak set is fetched from r0k.us (the usual mirror; Kodak released the
# images for unrestricted use). Only the fixtures need the network; nothing in
# the report does.
set -e
S="${SCRATCH:?set SCRATCH to your scratch directory}"
FF="${FFMPEG:-ffmpeg} -v error -y"
mkdir -p "$S/fx" "$S/kodak"
for k in 08 19 23; do
  f="$S/kodak/kodim$k.png"
  [ -f "$f" ] || curl -fsSL -o "$f" "https://r0k.us/graphics/kodak/kodak/kodim$k.png"
done
# kodim19 is portrait (512x768): pan vertically instead.
$FF -loop 1 -i "$S/kodak/kodim08.png" -vf "crop=640:480:'2*n':16,format=yuv420p" \
    -frames:v 30 -r 25 -c:v ffv1 "$S/fx/kodim08_pan.mkv"
$FF -loop 1 -i "$S/kodak/kodim23.png" -vf "crop=640:480:'2*n':16,format=yuv420p" \
    -frames:v 30 -r 25 -c:v ffv1 "$S/fx/kodim23_pan.mkv"
$FF -loop 1 -i "$S/kodak/kodim19.png" -vf "transpose=1,crop=640:480:'2*n':16,format=yuv420p" \
    -frames:v 30 -r 25 -c:v ffv1 "$S/fx/kodim19_pan.mkv"
ls -la "$S/fx"

# mpeg2stinx fixture: the progressive pans encoded the way a hard-telecined
# film DVD is (interlaced DCT + interlaced motion estimation, TFF, 4:2:0) at
# starved bitrates, then decoded. The progressive pan is the ground truth.
for k in 08 23; do
  for r in 1000 2000; do
    $FF -i "$S/fx/kodim${k}_pan.mkv" -vf setfield=tff -c:v mpeg2video -flags +ildct+ilme \
        -g 12 -bf 2 -b:v ${r}k -maxrate ${r}k -bufsize $((r * 2))k "$S/fx/kodim${k}_mpeg2_${r}.m2v"
    $FF -i "$S/fx/kodim${k}_mpeg2_${r}.m2v" -c:v ffv1 "$S/fx/kodim${k}_mpeg2_${r}.mkv"
  done
done
ls -la "$S/fx"
