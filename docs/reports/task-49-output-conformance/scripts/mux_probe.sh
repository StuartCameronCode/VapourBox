#!/usr/bin/env bash
# Task #49 step 0: which video encoder can the bundled FFmpeg mux into which
# container, and does each container record a field flag?
# Usage: mux_probe.sh <ffmpeg> <ffprobe>
set -u
FF=${1:?ffmpeg}; FP=${2:?ffprobe}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
"$FF" -version | head -1
encoders=(libx264 libx265 libsvtav1 ffv1 huffyuv ffvhuff "prores_ks -profile:v 0" "prores_ks -profile:v 4" v210)
pixfmts=(yuv420p yuv420p yuv420p yuv420p yuv422p yuv420p yuv422p10le yuv444p10le yuv422p10le)
printf '%-24s' encoder; for c in mp4 mov mkv avi; do printf '%-6s' $c; done; echo
for i in "${!encoders[@]}"; do
  enc=${encoders[$i]}; pf=${pixfmts[$i]}
  printf '%-24s' "$enc"
  for c in mp4 mov mkv avi; do
    if "$FF" -v error -y -f lavfi -i testsrc=s=64x64:d=0.2 -pix_fmt "$pf" -c:v $enc "$work/o.$c" 2>"$work/err"; then
      printf '%-6s' ok
    else
      printf '%-6s' FAIL
    fi
  done
  echo
done
echo
echo "field flag: -top 1 on the Y4M input, HuffYUV (no flag of its own)"
for c in mp4 mov mkv avi; do
  "$FF" -v error -y -f lavfi -i testsrc=s=64x48:d=0.2 -pix_fmt yuv420p -f yuv4mpegpipe - |
    "$FF" -v error -y -top 1 -f yuv4mpegpipe -i - -c:v huffyuv -pix_fmt yuv422p "$work/f.$c" 2>/dev/null ||
    { echo "$c: huffyuv refused"; continue; }
  fo=$("$FP" -v error -select_streams v -show_entries stream=field_order -of csv=p=0 "$work/f.$c")
  echo "$c huffyuv field_order=$fo"
done
# MP4 refuses HuffYUV: read its fiel atom with FFV1 instead (0209 = TFF).
"$FF" -v error -y -f lavfi -i testsrc=s=64x48:d=0.2 -pix_fmt yuv420p -f yuv4mpegpipe - |
  "$FF" -v error -y -top 1 -f yuv4mpegpipe -i - -c:v ffv1 "$work/f.mp4"
python3 -c "import sys;d=open(sys.argv[1],'rb').read();i=d.find(b'fiel');print('mp4 ffv1 fiel atom:',d[i+4:i+6].hex() if i>=0 else 'none')" "$work/f.mp4"
