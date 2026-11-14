#!/bin/bash
# Reproduces the flagging tables in ../index.html (P1-P5): what each codec and
# container records for a still-interlaced picture when the Y4M pipe input is
# given -top 1|0, what x264/x265's own interlace options write into the
# bitstream, and what AVFoundation reads back.
#
#   SCRATCH=/some/scratch/dir ./probe.sh
#
# Uses the repo's deps bundle (deps/<platform>, or $DEPS). Writes only under
# $SCRATCH. The source is Tests/TestResources/interlaced_test.avi (720x576 25i
# VHS capture, TFF by idet), decoded to a Y4M exactly as vspipe would pipe it:
# the header says `Ip` whatever the picture is.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
S="${SCRATCH:?set SCRATCH to your scratch directory}"
DEPS="${DEPS:-$REPO/deps/macos-arm64}"
FF="$DEPS/ffmpeg/ffmpeg"; FP="$DEPS/ffmpeg/ffprobe"
mkdir -p "$S"; cd "$S"

"$FF" -v error -y -i "$REPO/Tests/TestResources/interlaced_test.avi" -pix_fmt yuv420p \
  -f yuv4mpegpipe vhs.y4m
echo "Y4M header: $(head -c 60 vhs.y4m | head -1)"

fo()   { "$FP" -v error -select_streams v:0 -show_entries stream=field_order -of csv=p=0 "$1"; }
flags(){ "$FP" -v error -select_streams v:0 -read_intervals %+#1 \
           -show_entries frame=interlaced_frame,top_field_first -of csv=p=0 "$1" | head -1; }
fiel() { python3 -I "$HERE/fiel.py" "$1"; }
md5()  { "$FF" -v error -i "$1" -f md5 - | cut -d= -f2; }
# Header fields that say how the bitstream describes its pictures, with counts.
trace(){ "$FF" -v debug -i "$1" -c copy -bsf:v trace_headers -f null - 2>&1 \
  | grep -E " (frame_mbs_only_flag|mb_adaptive_frame_field_flag|field_seq_flag|pic_struct|delta_pic_order_cnt_bottom) " \
  | sed 's/.*\] //' | awk '{print $2"="$NF}' | sort | uniq -c | awk '{printf "%s x%s  ", $2, $1}'; }

echo
echo "== P1: lossless codecs, -top on the pipe input"
printf '%-8s %-4s %-5s %-12s %-6s %-10s %s\n' codec ext top field_order fiel "frame(i,t)" md5
for c in ffv1 ffvhuff huffyuv; do
  for ext in mkv mov avi; do
    for t in none 1 0; do
      A=(); [ "$t" != none ] && A=(-top "$t")
      out="$c.$t.$ext"
      "$FF" -v error -y ${A[@]+"${A[@]}"} -f yuv4mpegpipe -i vhs.y4m -c:v "$c" "$out"
      f="-"; [ "$ext" = mov ] && f="$(fiel "$out")"
      printf '%-8s %-4s %-5s %-12s %-6s %-10s %s\n' "$c" "$ext" "$t" "$(fo "$out")" "$f" "$(flags "$out")" "$(md5 "$out")"
    done
  done
done
echo "source md5 (yuv420p): $("$FF" -v error -f yuv4mpegpipe -i vhs.y4m -f md5 - | cut -d= -f2)"
echo "(HuffYUV is 4:2:2-only, so its decode differs from the 4:2:0 source; compare it with its own unflagged encode.)"

echo
echo "== P2: x264 (CRF 18, medium)"
x264() { # label out args...
  local label="$1" out="$2"; shift 2
  "$FF" -v error -y "$@" "$out"
  printf '%-44s size=%-8s fo=%-12s fiel=%-7s frame=%-5s sei=%s\n' "$label" "$(stat -f%z "$out" 2>/dev/null || stat -c%s "$out")" \
    "$(fo "$out")" "$(fiel "$out")" "$(flags "$out")" "$(strings "$out" | grep -o 'interlaced=[a-z0-9]*' | head -1)"
  echo "    $(trace "$out")"
}
X=(-c:v libx264 -crf 18 -preset medium)
x264 "progressive (before this change)"       a.mp4 -f yuv4mpegpipe -i vhs.y4m "${X[@]}"
x264 "-top 1 only"                            b.mp4 -top 1 -f yuv4mpegpipe -i vhs.y4m "${X[@]}"
x264 "-top 1 only (MKV)"                      b.mkv -top 1 -f yuv4mpegpipe -i vhs.y4m "${X[@]}"
x264 "-top 1 -flags +ildct"                   c.mp4 -top 1 -f yuv4mpegpipe -i vhs.y4m -flags +ildct "${X[@]}"
x264 "-top 0 -flags +ildct (BFF trap)"        d.mp4 -top 0 -f yuv4mpegpipe -i vhs.y4m -flags +ildct "${X[@]}"
x264 "-top 0 +ildct -x264-params bff=1"       e.mp4 -top 0 -f yuv4mpegpipe -i vhs.y4m -flags +ildct "${X[@]}" -x264-params bff=1
x264 "-top 1 +ildct -x264-params tff=1"       f.mp4 -top 1 -f yuv4mpegpipe -i vhs.y4m -flags +ildct "${X[@]}" -x264-params tff=1
x264 "-top 1 +ildct -x264-params tff=1 (MKV)" f.mkv -top 1 -f yuv4mpegpipe -i vhs.y4m -flags +ildct "${X[@]}" -x264-params tff=1
x264 "-x264-params fake-interlaced=1"         g.mkv -top 1 -f yuv4mpegpipe -i vhs.y4m "${X[@]}" -x264-params fake-interlaced=1
echo "pixels: progressive $(md5 a.mp4) / -top only $(md5 b.mp4) / fake $(md5 g.mkv)"
echo "pixels: BFF +ildct $(md5 d.mp4) / BFF bff=1 $(md5 e.mp4)"
for p in yuv420p10le yuv422p10le yuv444p; do
  "$FF" -v error -y -top 1 -f yuv4mpegpipe -i vhs.y4m -frames:v 10 -flags +ildct -pix_fmt $p -c:v libx264 -x264-params tff=1 hb.mkv
  echo "MBAFF at $p: $("$FP" -v error -select_streams v:0 -show_entries stream=profile,field_order -of csv=p=0 hb.mkv)"
done

echo
echo "== P3: x265 (CRF 18, medium)"
x265() {
  local label="$1" out="$2"; shift 2
  "$FF" -v error -y "$@" "$out"
  printf '%-36s fo=%-12s fiel=%-7s frame=%-5s md5=%s\n' "$label" "$(fo "$out")" "$(fiel "$out")" "$(flags "$out")" "$(md5 "$out")"
  echo "    $(trace "$out")"
}
Y=(-c:v libx265 -crf 18 -preset medium -tag:v hvc1)
x265 "progressive (before this change)" h.mp4 -f yuv4mpegpipe -i vhs.y4m "${Y[@]}" -x265-params log-level=error
x265 "-top 1"                           i.mp4 -top 1 -f yuv4mpegpipe -i vhs.y4m "${Y[@]}" -x265-params log-level=error
x265 "-top 1 (MKV)"                     i.mkv -top 1 -f yuv4mpegpipe -i vhs.y4m -c:v libx265 -crf 18 -x265-params log-level=error
x265 "-top 1 -x265-params interlace=tff" j.mp4 -top 1 -f yuv4mpegpipe -i vhs.y4m "${Y[@]}" -x265-params log-level=error:interlace=tff
x265 "interlace=tff:field=1"            k.mp4 -top 1 -f yuv4mpegpipe -i vhs.y4m "${Y[@]}" -x265-params log-level=error:interlace=tff:field=1

echo
echo "== P4: hardware encoders available here"
if "$FF" -hide_banner -encoders 2>/dev/null | grep -q h264_videotoolbox; then
  for c in h264_videotoolbox hevc_videotoolbox; do
    "$FF" -v error -y -top 1 -f yuv4mpegpipe -i vhs.y4m -flags +ildct -c:v $c -b:v 5M vt.$c.mp4
    echo "$c -top 1 +ildct: fo=$(fo vt.$c.mp4) fiel=$(fiel vt.$c.mp4) frame=$(flags vt.$c.mp4) $(trace vt.$c.mp4)"
  done
  echo "x264 MBAFF decoded by VideoToolbox: $("$FF" -v warning -hwaccel videotoolbox -i c.mp4 -f md5 - 2>&1 | tr '\n' ' ') (software $(md5 c.mp4))"
  echo "x264 progressive decoded by VideoToolbox: $("$FF" -v warning -hwaccel videotoolbox -i a.mp4 -f md5 - 2>&1 | tr '\n' ' ')"
else
  echo "no VideoToolbox in this build"
fi

echo
echo "== P5: AVFoundation (macOS only)"
if command -v swiftc >/dev/null; then
  swiftc -O -o fields "$HERE/fields.swift" 2>/dev/null
  ./fields a.mp4 c.mp4 e.mp4 h.mp4 i.mp4 j.mp4 ffv1.1.mov ffvhuff.1.mov huffyuv.1.mov ffv1.none.mov \
    | sed "s|$S/||"
  swiftc -O -o decode "$HERE/decode.swift" 2>/dev/null
  echo "-- full decode through AVAssetReader (MKV is not an AVFoundation format)"
  ./decode a.mp4 c.mp4 e.mp4 h.mp4 i.mp4 j.mp4
fi

echo
echo "== P6: VLC's automatic deinterlace (deinterlace=-1, mode auto), if installed"
VLC="${VLC:-/Applications/VLC.app/Contents/MacOS/VLC}"
if [ -x "$VLC" ]; then
  "$VLC" --version 2>/dev/null | head -1
  for f in a.mp4 c.mp4 e.mp4 f.mkv h.mp4 i.mp4 i.mkv j.mp4 \
           ffv1.none.mkv ffv1.1.mkv ffv1.1.avi ffvhuff.1.mkv ffvhuff.1.mov huffyuv.1.mkv huffyuv.1.mov; do
    if "$VLC" -I dummy --no-audio --vout=dummy --play-and-exit -vv "$f" 2>&1 \
         | grep -q "deinterlace filter debug: deinterlacing"; then
      echo "$f: deinterlaced"
    else
      echo "$f: shown as progressive"
    fi
  done
else
  echo "VLC not found (set \$VLC)"
fi
