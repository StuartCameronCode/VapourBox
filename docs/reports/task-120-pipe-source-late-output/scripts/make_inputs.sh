#!/bin/bash
# The raw inputs the probes read on stdin. Run from this directory with
# FFMPEG=<bundle>/ffmpeg/ffmpeg and REPO=<repository root>.
set -e
"$FFMPEG" -v error -y -i "$REPO/Tests/TestResources/interlaced_test.avi" \
  -f rawvideo -pix_fmt yuv422p raw.yuv                      # stab*.vpy
"$FFMPEG" -v error -y -i "$REPO/Tests/TestResources/interlaced_test.avi" -frames:v 50 \
  -vf scale=720:480 -f rawvideo -pix_fmt yuv444p16le raw444.yuv   # pitch.vpy
"$FFMPEG" -v error -y -f lavfi -i testsrc2=s=64x48:r=25 -frames:v 120 \
  -f rawvideo -pix_fmt yuv420p raw64.yuv                    # late_output.vpy
"$FFMPEG" -v error -y -f lavfi -i testsrc2=s=1920x1080:r=25 -frames:v 300 \
  -f rawvideo -pix_fmt yuv420p raw1080.yuv                  # ovh.vpy
