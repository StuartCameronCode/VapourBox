#!/bin/bash
# Synthetic sources for the vspipe vs FFmpeg-demuxer comparison.
# testsrc2 + temporal noise, so denoisers/deinterlacers have real work; FFV1 so
# the decoder is cheap and lossless. Usage: gen_sources.sh <ffmpeg> <outdir>
set -euo pipefail
FF="$1"; OUT="$2"; mkdir -p "$OUT"
"$FF" -v error -y -f lavfi -i "testsrc2=size=720x576:rate=25,noise=alls=12:allf=t" \
  -frames:v 500 -pix_fmt yuv420p -c:v ffv1 "$OUT/sd.mkv"
"$FF" -v error -y -f lavfi -i "testsrc2=size=1920x1080:rate=25,noise=alls=12:allf=t" \
  -frames:v 200 -pix_fmt yuv420p -c:v ffv1 "$OUT/hd.mkv"
