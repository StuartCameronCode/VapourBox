#!/bin/bash
# Sources for the ffmpeg-only measurements (candidates.py, xcorr.py): video and
# sound from 0, 25 fps, 100 pictures, white at 25 and 75, a 1 kHz beep at 1 s
# and 3 s over a 300 Hz bed, mono; the sound encoded by ffmpeg (so primed) at
# 128k into MKV or MP4. master*.mkv (FLAC) is the unprimed control.
#   fixtures.sh <ffmpeg dir> <out dir>
set -euo pipefail
F="$1"; OUT="$2"; mkdir -p "$OUT"; cd "$OUT"
VIDEO="testsrc2=size=320x240:rate=25:duration=4,drawbox=c=white:t=fill:enable='eq(n\,25)+eq(n\,75)'"
BEEPS="0.6*sin(2*PI*1000*t)*(between(t\,1\,1.04)+between(t\,3\,3.04))+0.05*sin(2*PI*300*t)"
for r in 48000 44100; do
  "$F/ffmpeg" -y -v error -f lavfi -i "$VIDEO" -f lavfi -i "aevalsrc=${BEEPS}:s=${r}:d=4:c=mono" \
    -map 0:v -map 1:a -c:v ffv1 -c:a flac master$r.mkv
done
mk(){ src=$1; out=$2; shift 2; "$F/ffmpeg" -y -v error -i $src -map 0 -c:v libx264 -preset veryfast -g 25 -pix_fmt yuv420p "$@" $out; }
mk master48000.mkv aac.mkv -c:a aac -b:a 128k
mk master48000.mkv aac.mp4 -c:a aac -b:a 128k
mk master48000.mkv mp3.mkv -c:a libmp3lame -b:a 128k
mk master48000.mkv mp3.mp4 -c:a libmp3lame -b:a 128k
mk master48000.mkv ac3.mkv -c:a ac3 -b:a 128k
mk master48000.mkv mp2.mkv -c:a mp2 -b:a 128k
mk master48000.mkv aac_stereo.mkv -c:a aac -b:a 128k -ac 2
mk master44100.mkv aac44.mkv -c:a aac -b:a 128k
mk master44100.mkv mp3_44.mkv -c:a libmp3lame -b:a 128k
# 60 fps: a priming of 5-10 ms against a 16.7 ms frame.
for c in mp2 ac3; do
  "$F/ffmpeg" -y -v error -f lavfi -i "testsrc2=size=320x240:rate=60:duration=4" -f lavfi -i "sine=f=300:r=48000:d=4" \
    -map 0:v -map 1:a -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a $c -b:a 192k ${c}_60.mkv
done
