#!/bin/bash
# quality.sh <ffmpeg> <src: 720x486 4:2:0 TFF, lossless> <bitrate>
# x264 at an equal ABR bitrate (preset medium): progressive at 486 lines, MBAFF
# at 484 (2 rows cropped), MBAFF at 488 (2 rows padded). Per-field PSNR over the
# 484 rows all three keep, frame by frame: setpts=N/(25*TB) on both sides, so
# the psnr filter's timestamp sync can't pair the wrong frames, and the field
# count is printed to show it didn't.
set -euo pipefail
F=$1; SRC=$2; BR=$3; P=${F%ffmpeg}ffprobe
"$F" -v error -y -i "$SRC" -fps_mode passthrough -f rawvideo -pix_fmt yuv420p src.yuv
raw() { "$F" -v error -f rawvideo -pix_fmt yuv420p -s 720x486 -r 25 -i src.yuv -vf "$1" -f yuv4mpegpipe - ; }
mbaff=(-flags +ildct -x264-params tff=1)
raw null             | "$F" -v error -y -top 1 -f yuv4mpegpipe -i - -c:v libx264 -b:v "$BR" prog486.mkv
raw crop=720:484:0:0 | "$F" -v error -y -top 1 -f yuv4mpegpipe -i - -c:v libx264 -b:v "$BR" "${mbaff[@]}" mbaff484.mkv 2>/dev/null
raw pad=720:488:0:0  | "$F" -v error -y -top 1 -f yuv4mpegpipe -i - -c:v libx264 -b:v "$BR" "${mbaff[@]}" mbaff488.mkv 2>/dev/null
for f in prog486 mbaff484 mbaff488; do
  n=$("$P" -v error -count_frames -select_streams v -show_entries stream=nb_read_frames -of csv=p=0 $f.mkv)
  size=$(stat -f %z $f.mkv 2>/dev/null || stat -c %s $f.mkv)
  psnr=$("$F" -v error -i $f.mkv -f rawvideo -pix_fmt yuv420p -s 720x486 -r 25 -i src.yuv -lavfi \
    "[0]setpts=N/(25*TB),crop=720:484:0:0,setfield=tff,separatefields[a];[1]setpts=N/(25*TB),crop=720:484:0:0,setfield=tff,separatefields[b];[a][b]psnr=stats_file=-" \
    -f null - 2>/dev/null | awk '{for(i=1;i<=NF;i++){split($i,kv,":"); if(kv[1]=="psnr_y")y+=kv[2]; if(kv[1]=="psnr_avg")a+=kv[2]}; n++} END{printf "Y %.2f dB, avg %.2f dB (%d fields)", y/n, a/n, n}')
  printf "%-9s %3d frames %9d bytes  per-field PSNR %s\n" $f "$n" "$size" "$psnr"
done
rm -f src.yuv
