#!/usr/bin/env bash
# Task #73: which colour matrices FFmpeg's scale can convert.
#   FFMPEG=/path/to/deps/<platform>/ffmpeg/ffmpeg  (default: the repo's deps)
#   SCRATCH=<dir> for the generated frames (default: a new mktemp dir)
# Prints three tables: the preview's scale on an untagged Y4M per in_color_matrix
# name and per numeric value, and converting decodes of a file TAGGED with each
# matrix (what the app's before frame, thumbnails and detectors do).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) PLAT=macos-arm64 ;; Darwin-x86_64) PLAT=macos-x64 ;;
  Linux-aarch64) PLAT=linux-arm64 ;; *) PLAT=linux-x64 ;;
esac
FFMPEG="${FFMPEG:-$ROOT/deps/$PLAT/ffmpeg/ffmpeg}"
SCRATCH="${SCRATCH:-$(mktemp -d)}"
cd "$SCRATCH" || exit 1
Q=(-hide_banner -loglevel error -y)
"$FFMPEG" -version | head -1
echo
echo "## scale's in_color_matrix constants"
"$FFMPEG" -hide_banner -h filter=scale 2>&1 | sed -n '/in_color_matrix/,/out_color_matrix/p' | sed '$d'
"$FFMPEG" "${Q[@]}" -f lavfi -i testsrc2=s=96x64:r=25 -frames:v 1 -pix_fmt yuv420p src.y4m
TAIL=":in_range=tv:out_range=pc:flags=accurate_rnd+full_chroma_int"
echo
echo "## The preview's scale on an untagged Y4M (md5 of the rgb24 output)"
for m in auto bt601 bt470bg smpte170m bt709 fcc smpte240m bt2020 bt2020nc \
         ycgco bt2020c smpte2085 chroma-derived-nc chroma-derived-c ictcp \
         8 10 11 12 13 14; do
  rm -f o.rgb
  err=$("$FFMPEG" "${Q[@]}" -f yuv4mpegpipe -i src.y4m -frames:v 1 \
        -vf "scale=in_color_matrix=$m$TAIL" -f rawvideo -pix_fmt rgb24 o.rgb 2>&1 | grep -v '^\[AVFilterGraph' | head -1)
  if [ -s o.rgb ]; then r="ok $(md5sum o.rgb 2>/dev/null | cut -c1-8 || md5 -q o.rgb | cut -c1-8)"; else r="FAIL: ${err#*] }"; fi
  printf '%-18s %s\n' "$m" "$r"
done
echo
echo "## Converting decodes of a yuv420p FFV1 file tagged with the matrix"
for m in bt709 ycgco bt2020c smpte2085 chroma-derived-nc chroma-derived-c ictcp; do
  "$FFMPEG" "${Q[@]}" -f lavfi -i testsrc2=s=96x64:r=25 -frames:v 3 \
    -vf "format=yuv420p,setparams=colorspace=$m" -c:v ffv1 "t_$m.mkv"
  line="$m:"
  for to in "-f rawvideo -pix_fmt yuv420p same.raw" "-q:v 2 b.jpg" \
            "-f rawvideo -pix_fmt rgb24 r.raw" "-f rawvideo -pix_fmt gray16le g.raw" \
            "-f rawvideo -pix_fmt yuv422p p.raw"; do
    # shellcheck disable=SC2086
    if "$FFMPEG" "${Q[@]}" -i "t_$m.mkv" -frames:v 1 $to >/dev/null 2>&1; then s=ok; else s=FAIL; fi
    line="$line ${to##* }=$s"
  done
  if "$FFMPEG" "${Q[@]}" -i "t_$m.mkv" -frames:v 1 -vf "setparams=colorspace=unknown" \
       -f rawvideo -pix_fmt rgb24 n.raw >/dev/null 2>&1; then s=ok; else s=FAIL; fi
  echo "$line cleared-first-rgb=$s"
done
