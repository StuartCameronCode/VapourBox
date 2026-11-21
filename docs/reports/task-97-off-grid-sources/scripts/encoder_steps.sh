#!/bin/bash
# Which encoders store a picture cropped to 63x33 from 64x34, in each format
# (table "Which encoders store an off-grid size"; VideoCodec::size_step).
source "$(dirname "$0")/common.sh"
for pf in yuv420p yuv422p yuv422p10le yuv444p; do
  for spec in "libx264 mp4" "libx265 mp4" "libsvtav1 mp4" "ffv1 mkv" "huffyuv avi" "ffvhuff avi" \
              "prores_ks mov" "v210 mov" "h264_videotoolbox mp4" "hevc_videotoolbox mp4"; do
    set -- $spec; out="$WORK/step_$1_$pf.$2"
    if "$FF" -v error -y -f lavfi -i testsrc2=s=64x34:r=25:d=0.2 -vf "format=$pf,crop=63:33:0:0:exact=1" -c:v "$1" "$out" 2>/dev/null; then
      echo "$pf 63x33 -> $1: stored $(size "$out")"
    else
      echo "$pf 63x33 -> $1: refused"
    fi
  done
done
