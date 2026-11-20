#!/bin/bash
# Task #76: what FFmpeg 9 does with frames TAGGED with a matrix its scaler has
# no conversion for, and what the fixes give.
#
# Usage: probe-unconvertible-matrices.sh <path to ffmpeg> <empty work dir>
# (ffprobe is taken from beside ffmpeg). Prints the tables of the report.
# Every fixture is testsrc2, retagged with setparams (no sample converted).
set -u
F=$1; D=$2; P=$(dirname "$F")/ffprobe
mkdir -p "$D"; cd "$D" || exit 1
"$F" -version | head -1
M="unknown bt709 bt2020nc ycgco bt2020c smpte2085 chroma-derived-nc chroma-derived-c ictcp"
for m in $M; do
  "$F" -v error -y -f lavfi -i testsrc2=s=96x64 -frames:v 3 \
    -vf "format=yuv420p,setparams=colorspace=${m}:color_primaries=bt709:color_trc=bt709:range=tv" \
    -c:v ffv1 "t_${m}.mkv"
done

echo; echo "## 1. Decodes of a yuv420p FFV1 tagged <m>"
echo "outputs: jpg rgb24 gray16le yuv422p yuv420p(same) thumb(scale=160:-1 jpg) png yuv420p10le null"
for m in $M; do
  r=""
  for out in "b.jpg" "-pix_fmt rgb24 -f rawvideo o.raw" "-pix_fmt gray16le -f rawvideo o.raw" \
             "-pix_fmt yuv422p -f rawvideo o.raw" "-pix_fmt yuv420p -f rawvideo o.raw" \
             "-vf scale=160:-1 c.jpg" "b.png" "-pix_fmt yuv420p10le -f rawvideo o.raw" "-f null -"; do
    "$F" -v error -y -i "t_${m}.mkv" -frames:v 1 $out >/dev/null 2>&1 && r="$r ok" || r="$r FAIL"
  done
  echo "$m:$r"
done
echo "negotiation message:"
"$F" -v error -y -i t_ycgco.mkv -frames:v 1 -pix_fmt rgb24 -f rawvideo o.raw 2>&1 | grep -A3 "Color spaces" | head -4

echo; echo "## 2. setparams=colorspace=X first: md5 of the decoded frame (6 hex)"
for out in "jpg:-f image2 -c:v mjpeg" "rgb24:-pix_fmt rgb24 -f rawvideo" "gray16le:-pix_fmt gray16le -f rawvideo" \
           "yuv422p:-pix_fmt yuv422p -f rawvideo" "yuv444p:-pix_fmt yuv444p -f rawvideo" \
           "yuv420p10le:-pix_fmt yuv420p10le -f rawvideo" "nv12:-pix_fmt nv12 -f rawvideo"; do
  name=${out%%:*}; args=${out#*:}
  line="$name:"
  for src in ycgco bt2020c; do
    for x in unknown bt709 bt470bg bt2020nc; do
      h=$("$F" -v error -y -i "t_${src}.mkv" -frames:v 1 -vf "setparams=colorspace=${x}" $args - 2>/dev/null | md5 | cut -c1-6)
      line="$line ${src}->${x}=$h"
    done
  done
  line="$line | untagged=$("$F" -v error -y -i t_unknown.mkv -frames:v 1 $args - 2>/dev/null | md5 | cut -c1-6)"
  line="$line bt709=$("$F" -v error -y -i t_bt709.mkv -frames:v 1 $args - 2>/dev/null | md5 | cut -c1-6)"
  echo "$line"
done

echo; echo "## 3. Encoder: Y4M input declared with the tag (md5 of the stored samples, 6 hex)"
"$F" -v error -y -f lavfi -i testsrc2=s=96x64 -frames:v 3 -pix_fmt yuv420p -f yuv4mpegpipe in.y4m
"$F" -v error -y -f lavfi -i testsrc2=s=96x64 -frames:v 3 -pix_fmt yuv420p10le -strict -1 -f yuv4mpegpipe in10.y4m
"$F" -v error -y -f lavfi -i testsrc2=s=96x64 -frames:v 3 -pix_fmt yuv422p10le -strict -1 -f yuv4mpegpipe in422.y4m
printf '1\n00:00:00,000 --> 00:00:05,000\nHello\n' > s.srt
enc() { # label codec input input-args output-args
  if "$F" -v error -y -f yuv4mpegpipe $4 -i "$3" $5 -c:v "$2" e.mkv 2>err.txt; then
    cs=$("$P" -v error -select_streams v:0 -show_entries stream=color_space,pix_fmt -of csv=p=0 e.mkv)
    h=$("$F" -v error -i e.mkv -vf setparams=colorspace=unknown -f rawvideo -pix_fmt yuv444p16le - | md5 | cut -c1-6)
    echo "$1: ok [$cs] $h"
  else echo "$1: FAIL $(grep -m1 -v '^ ' err.txt | head -c 110)"; fi
}
BR="setparams=colorspace=unknown,scale,setparams=colorspace=ycgco"
enc "x264 nv12, untagged" libx264 in.y4m "" "-pix_fmt nv12"
enc "x264 nv12, ycgco both sides" libx264 in.y4m "-colorspace ycgco" "-colorspace ycgco -pix_fmt nv12"
enc "x264 nv12, input unknown, output ycgco" libx264 in.y4m "" "-colorspace ycgco -pix_fmt nv12"
enc "x264 nv12, ycgco, bridge" libx264 in.y4m "-colorspace ycgco" "-colorspace ycgco -vf $BR -pix_fmt nv12"
enc "x264 10-bit no conversion, untagged" libx264 in10.y4m "" ""
enc "x264 10-bit no conversion, ycgco" libx264 in10.y4m "-colorspace ycgco" "-colorspace ycgco"
enc "x264 10-bit no conversion, ycgco, bridge" libx264 in10.y4m "-colorspace ycgco" "-colorspace ycgco -vf $BR"
enc "x264 422p10 to 420, untagged" libx264 in422.y4m "" "-pix_fmt yuv420p"
enc "x264 422p10 to 420, ycgco" libx264 in422.y4m "-colorspace ycgco" "-colorspace ycgco -pix_fmt yuv420p"
enc "x264 422p10 to 420, ycgco, bridge" libx264 in422.y4m "-colorspace ycgco" "-colorspace ycgco -vf $BR -pix_fmt yuv420p"
enc "huffyuv (implicit 420->422), untagged" huffyuv in.y4m "" ""
enc "huffyuv (implicit 420->422), ycgco" huffyuv in.y4m "-colorspace ycgco" "-colorspace ycgco"
enc "huffyuv (implicit 420->422), ycgco, bridge" huffyuv in.y4m "-colorspace ycgco" "-colorspace ycgco -vf $BR"
enc "subtitles burn-in, untagged" libx264 in10.y4m "" "-vf subtitles=s.srt"
enc "subtitles burn-in, ycgco" libx264 in10.y4m "-colorspace ycgco" "-colorspace ycgco -vf subtitles=s.srt"

echo; echo "## 4. HDR display tone map on an untagged 10-bit Y4M (the worker's preview)"
"$F" -v error -y -f lavfi -i testsrc2=s=192x108 -frames:v 1 -vf format=yuv420p10le -strict -1 -f yuv4mpegpipe x.y4m
for trc in smpte2084 arib-std-b67; do for m in bt2020c bt2020nc; do
  TM="setparams=colorspace=${m}:color_primaries=bt2020:color_trc=${trc}:range=tv,zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:r=full,format=rgb24,setparams=colorspace=gbr"
  "$F" -v error -y -i x.y4m -vf "$TM" o.png 2>err.txt && echo "$trc $m: ok" || echo "$trc $m: FAIL $(head -1 err.txt)"
done; done
