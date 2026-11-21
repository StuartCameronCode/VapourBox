#!/bin/bash
# refusals.sh <ffmpeg> <vhs422.mkv> <vhs420.mkv>
# 1. Which output formats libx264 codes interlaced (as the worker runs it: Y4M
#    pipe, -top 1 on its input, -flags +ildct -x264-params tff=1) at 720x486.
# 2. Whether 488 lines padded and 2 cropped (H.264 SPS cropping) can express it.
F=$1; S422=$2; S420=$3; P=${F%ffmpeg}ffprobe
y4m() { "$F" -v error -i "$1" -t 0.4 -vf "$2" -f yuv4mpegpipe -strict -1 - 2>/dev/null; }
probe() { "$P" -v error -select_streams v -show_entries stream=profile,width,height,pix_fmt -of compact=p=0 "$1"; }
echo "# 1. MBAFF at 720x486, by output format"
for pf in yuv420p yuv420p10le yuv422p yuv444p; do
  err=$(y4m "$S422" "scale=interl=1,format=$pf" | "$F" -v error -y -top 1 -f yuv4mpegpipe -i - \
        -c:v libx264 -flags +ildct -x264-params tff=1 t.mkv 2>&1 | grep libx264 | head -1)
  echo "$pf: ${err:-ok $(probe t.mkv)}"
done
err=$(y4m "$S420" null | "$F" -v error -y -top 1 -f yuv4mpegpipe -i - -c:v libx264 t.mkv 2>&1 | head -1)
echo "yuv420p progressive: ${err:-ok $(probe t.mkv)}"
echo "# 2. pad to 488, then crop-rect (left,top,right,bottom)"
for cr in 0,0,0,2 0,2,0,0 0,0,0,4; do
  err=$(y4m "$S420" pad=720:488:0:0 | "$F" -v error -y -top 1 -f yuv4mpegpipe -i - \
        -c:v libx264 -flags +ildct -x264-params "tff=1:crop-rect=$cr" c.mkv 2>&1 | grep libx264 | head -1)
  echo "crop-rect $cr: ${err:-ok $(probe c.mkv)}"
done
