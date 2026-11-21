#!/bin/bash
# other_codecs.sh <ffmpeg> <src: 720x486 4:2:0 TFF>
# Each codec's interlaced path at 720x486 as the worker runs it: the format the
# script delivers, -top 1 on the Y4M input, the codec's field-order args
# (pipeline_executor::field_order_args). Then ProRes's last rows against a
# lossless 4:2:2 reference, to catch a broken last field row.
F=$1; SRC=$2; P=${F%ffmpeg}ffprobe
y4m() { "$F" -v error -i "$SRC" -frames:v 10 -vf "scale=interl=1,format=$1" -f yuv4mpegpipe -strict -1 - 2>/dev/null; }
run() { # run <label> <pix_fmt> <out> <encoder args...>
  local label=$1 pf=$2 out=$3; shift 3
  err=$(y4m "$pf" | SVT_LOG=2 "$F" -v error -y -top 1 -f yuv4mpegpipe -i - "$@" "$out" 2>&1 | grep -iv weightp | head -1)
  if [ -n "$err" ]; then echo "$label: FAIL $err"; else
    echo "$label: ok $("$P" -v error -select_streams v -show_entries stream=codec_name,profile,height,pix_fmt -of compact=p=0:nk=1 "$out")"; fi
}
run "x264 MBAFF 4:2:0"          yuv420p     a.mkv -c:v libx264 -flags +ildct -x264-params tff=1
run "x264 MBAFF 4:2:0 10-bit"   yuv420p10le a.mkv -c:v libx264 -flags +ildct -x264-params tff=1
run "x264 MBAFF 4:2:2"          yuv422p     a.mkv -c:v libx264 -flags +ildct -x264-params tff=1
run "x264 progressive 4:2:0"    yuv420p     a.mkv -c:v libx264
run "x265 4:2:0"                yuv420p     a.mkv -c:v libx265
run "ProRes 422 HQ +ildct"      yuv422p10le pr.mov -c:v prores_ks -profile:v 3 -flags +ildct
run "ProRes 4444 +ildct"        yuv444p10le a.mov -c:v prores_ks -profile:v 4 -flags +ildct
run "v210"                      yuv422p10le a.mov -c:v v210
run "FFV1 4:2:0"                yuv420p     a.mkv -c:v ffv1
run "HuffYUV 4:2:2"             yuv422p     a.mkv -c:v huffyuv
run "FFVHuff 4:2:0"             yuv420p     a.mkv -c:v ffvhuff
run "AV1 (SVT-AV1) 4:2:0"       yuv420p     a.mp4 -c:v libsvtav1
run "VideoToolbox H.264"        yuv420p     a.mp4 -c:v h264_videotoolbox -b:v 4M
run "VideoToolbox H.264 +ildct" yuv420p     a.mp4 -c:v h264_videotoolbox -b:v 4M -flags +ildct
run "VideoToolbox HEVC"         yuv420p     a.mp4 -c:v hevc_videotoolbox -b:v 4M
y4m yuv422p10le | "$F" -v error -y -f yuv4mpegpipe -i - -c:v ffv1 ref.mkv
for c in 720:486:0:0 720:8:0:478 720:2:0:484; do
  echo "ProRes HQ +ildct vs source, rows $c: PSNR $("$F" -hide_banner -i pr.mov -i ref.mkv \
    -lavfi "[0]crop=$c[a];[1]crop=$c[b];[a][b]psnr" -f null - 2>&1 | grep -o 'average:[0-9.inf]*')"
done
