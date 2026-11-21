#!/bin/bash
# Which encoders in the bundled FFmpeg write a 63x33 picture as it is
# (table "Which encoders write such sources").
source "$(dirname "$0")/common.sh"
for spec in "libvpx-vp9 yuv420p webm" "libvpx yuv420p webm" "libaom-av1 yuv420p mkv" "libsvtav1 yuv420p mkv" \
            "mjpeg yuvj420p avi" "mjpeg yuvj422p mov" "mpeg4 yuv420p avi" "mpeg2video yuv420p mpg" \
            "magicyuv yuv420p avi" "rawvideo yuv420p avi" "ffv1 yuv420p mkv" "prores_ks yuv422p10le mov" \
            "libx264 yuv420p mp4" "libx265 yuv420p mp4" "h264_videotoolbox yuv420p mp4" \
            "huffyuv yuv422p avi" "ffvhuff yuv420p avi" "utvideo yuv420p avi" "dnxhd yuv422p mov" \
            "cfhd yuv422p10le mov" "dvvideo yuv411p avi"; do
  set -- $spec; out="$WORK/$1.$3"
  if "$FF" -v error -y -f lavfi -i testsrc2=s=128x96:r=25:d=0.4 -vf "scale=63:33,format=$2" -c:v "$1" "$out" 2>/dev/null; then
    echo "$1 ($2): writes $(size "$out")"
  else
    echo "$1 ($2): refused"
  fi
done
