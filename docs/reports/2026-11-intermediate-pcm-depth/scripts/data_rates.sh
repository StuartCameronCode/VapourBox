#!/bin/sh
# F5: the video data rate the 24-bit track sits beside — 4 s of 720x576 25p
# (a VHS/DV capture's size), testsrc2 with temporal noise for a realistic
# ProRes rate, as ProRes 422 Proxy, ProRes 422 HQ and v210; and 1080p25 HQ.
#   FFMPEG=<deps>/ffmpeg/ffmpeg WORK=/scratch ./data_rates.sh
set -e
: "${FFMPEG:?}" "${WORK:?}"
FP="$(dirname "$FFMPEG")/ffprobe"
mkdir -p "$WORK/rates"
rate() {  # name size codec-args...
  name=$1; size=$2; shift 2
  "$FFMPEG" -hide_banner -loglevel error -y -f lavfi \
    -i "testsrc2=s=$size:r=25:d=4,noise=alls=12:allf=t+u,format=yuv422p10le" "$@" "$WORK/rates/$name.mov"
  printf '%-22s %8.1f Mbit/s\n' "$name" "$("$FP" -v error -select_streams v -show_entries stream=bit_rate -of csv=p=0 "$WORK/rates/$name.mov" | awk '{print $1/1e6}')"
}
rate prores_proxy_576p25 720x576 -c:v prores_ks -profile:v 0
rate prores_hq_576p25 720x576 -c:v prores_ks -profile:v 3
rate v210_576p25 720x576 -c:v v210
rate prores_hq_1080p25 1920x1080 -c:v prores_ks -profile:v 3
echo "48 kHz stereo PCM: 16-bit 1.536 Mbit/s, 24-bit 2.304 Mbit/s (+0.768)"
