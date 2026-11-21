#!/bin/bash
# make_fixtures.sh <ffmpeg> <Tests/TestResources> <out dir>
# 720x486 cuts of two interlaced fixtures, cropped at an even offset (44) so
# the field order holds; 4:2:0 converted field by field. Lossless (FFV1).
set -euo pipefail
F=$1; R=$2; O=$3
"$F" -v error -y -i "$R/interlaced_test.avi" -vf "crop=720:486:0:44" -pix_fmt yuv422p -c:v ffv1 "$O/vhs422.mkv"
"$F" -v error -y -i "$O/vhs422.mkv" -vf "scale=interl=1,format=yuv420p" -c:v ffv1 "$O/vhs420.mkv"
"$F" -v error -y -i "$R/pal-dvbt-fieldcoded-25i.ts" -vf "crop=720:486:0:44" -pix_fmt yuv420p -c:v ffv1 "$O/dvb420.mkv"
