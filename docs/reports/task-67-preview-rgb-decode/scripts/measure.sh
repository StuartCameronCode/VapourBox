#!/bin/bash
# One frame per fixture, converted to RGB two ways, and how far apart they are
# (task #67, table 1 of the report):
#   A  what WorkerHarness.frameRgb24 does: the frame to PNG with ffmpeg's
#      automatic conversion, then PNG -> rgb24 (default flags);
#   B  what the preview does since task #56 F8: the frame through
#      scale=[in_color_matrix=<tag>:]in_range=<tv|pc>:out_range=pc:
#      flags=accurate_rnd+full_chroma_int, to PNG, then PNG -> rgb24.
# Both end in the same PNG -> rgb24 step, so the difference is the YUV -> RGB
# conversion alone.
#
# usage: measure.sh            (FFMPEG defaults to the repo's deps/<platform>)
#        SCRATCH=<dir> for the derived fixtures and frames (default: mktemp)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
RES="$REPO/Tests/TestResources"
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) PLAT=macos-arm64 ;; Darwin-x86_64) PLAT=macos-x64 ;;
  Linux-x86_64) PLAT=linux-x64 ;; Linux-aarch64) PLAT=linux-arm64 ;;
esac
FF="${FFMPEG:-$REPO/deps/$PLAT/ffmpeg/ffmpeg}"
FP="${FFPROBE:-$(dirname "$FF")/ffprobe}"
O="${SCRATCH:-$(mktemp -d)}"; mkdir -p "$O"
N=20

# The preview's scale for a file's own tags (WorkerHarness.previewScaleFilter).
scale_for() {
  local m r
  m=$("$FP" -v error -select_streams v:0 -show_entries stream=color_space -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n1 | tr -d "[:space:]")
  r=$("$FP" -v error -select_streams v:0 -show_entries stream=color_range -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n1 | tr -d "[:space:]")
  local opts=""
  case "$m" in rgb|unknown|reserved|"") ;; *) opts="in_color_matrix=$m:" ;; esac
  case "$r" in pc|jpeg|full) opts="${opts}in_range=pc" ;; *) opts="${opts}in_range=tv" ;; esac
  echo "scale=$opts:out_range=pc:flags=accurate_rnd+full_chroma_int"
}

measure() {  # file label
  local f="$1" label="$2"
  "$FF" -y -v quiet -i "$f" -vf "select=eq(n\,$N)" -frames:v 1 "$O/a.png"
  "$FF" -y -v quiet -i "$O/a.png" -f rawvideo -pix_fmt rgb24 "$O/a.rgb"
  "$FF" -y -v quiet -i "$f" -vf "select=eq(n\,$N),$(scale_for "$f")" -frames:v 1 "$O/b.png"
  "$FF" -y -v quiet -i "$O/b.png" -f rawvideo -pix_fmt rgb24 "$O/b.rgb"
  local fmt
  fmt=$("$FP" -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=nw=1:nk=1 "$f" 2>/dev/null | head -n1)
  python3 - "$O/a.rgb" "$O/b.rgb" "$label" "$fmt" <<'PY'
import sys
a = open(sys.argv[1], 'rb').read(); b = open(sys.argv[2], 'rb').read()
assert len(a) == len(b)
d = [abs(x - y) for x, y in zip(a, b)]
print(f"{sys.argv[3]:<44} {sys.argv[4]:<14} mean {sum(d)/len(d):.3f}  max {max(d)}")
PY
}

for f in blended_film_50i.mkv small_clip.mp4 pal-dvbt-fieldcoded-25i.ts \
         face_restore_test.mp4 interlaced_test.avi pal-sd-25.mov \
         prores422_10bit_telecine.mov late_video.mkv seek_dvd_pal.mpg; do
  measure "$RES/$f" "$f"
done

# small_clip in other layouts: lossless FFV1 copies, 40 frames.
for pf in yuv422p yuv420p:full yuv420p10le yuv422p10le yuv444p; do
  fmt=${pf%%:*}; extra=()
  [[ "$pf" == *:full ]] && extra=(-color_range pc)
  out="$O/small_clip_${pf/:/_}.mkv"
  "$FF" -y -v quiet -i "$RES/small_clip.mp4" -frames:v 40 -an \
    -vf "scale=flags=accurate_rnd+full_chroma_int${extra[0]+:out_range=pc}" \
    -pix_fmt "$fmt" ${extra[@]+"${extra[@]}"} -c:v ffv1 "$out"
  measure "$out" "small_clip -> $pf"
done
