#!/bin/bash
# Reproduces every number in ../index.html: what field order a still-interlaced
# v210 / ProRes encode declares (P1-P6), whether FFmpeg's 4:2:0 -> 4:2:2
# conversion keeps each field's chroma (P7), and v210's containers and data
# rate (P8).
#
#   SCRATCH=/some/scratch/dir ./probe.sh
#
# Uses the repo's deps bundle (deps/<platform>, or $DEPS). Writes only under
# $SCRATCH.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
S="${SCRATCH:?set SCRATCH to your scratch directory}"
DEPS="${DEPS:-$REPO/deps/macos-arm64}"
FF="$DEPS/ffmpeg/ffmpeg"; FP="$DEPS/ffmpeg/ffprobe"; VSPIPE="$DEPS/vapoursynth/vspipe"
mkdir -p "$S"; cd "$S"

fiel() { python3 -c "import sys;d=open(sys.argv[1],'rb').read();i=d.find(b'fiel');print(d[i+4:i+6].hex() if i>0 else 'absent')" "$1"; }
fo()   { "$FP" -v error -select_streams v:0 -show_entries stream=field_order -of csv=p=0 "$1"; }
hdr()  { "$FP" -v error -select_streams v:0 -read_intervals %+#1 \
           -show_entries frame=interlaced_frame,top_field_first -of csv=p=0 "$1"; }

echo "== P1: vspipe's Y4M header for a clip marked _FieldBased=2 (TFF)"
cat > fb.vpy <<'PY'
import vapoursynth as vs
c = vs.core.std.BlankClip(width=720, height=576, format=vs.YUV422P10, length=10, fpsnum=25)
vs.core.std.SetFieldBased(c, 2).set_output()
PY
"$VSPIPE" -c y4m fb.vpy in.y4m >/dev/null 2>&1
head -c 60 in.y4m | head -1

echo "== P2-P5: MOV fiel atom / ffprobe field_order / ProRes frame header"
printf '%-34s %-6s %-12s %s\n' case fiel field_order "frame(interlaced,tff)"
run() { # label outfile args...
  local label="$1" out="$2"; shift 2
  "$FF" -v error -y "$@" "$out"
  printf '%-34s %-6s %-12s %s\n' "$label" "$(fiel "$out")" "$(fo "$out")" "$(hdr "$out")"
}
run "v210, nothing"                 a.mov  -f yuv4mpegpipe -i in.y4m -c:v v210
run "v210, -field_order tt (output)" b.mov -f yuv4mpegpipe -i in.y4m -c:v v210 -field_order tt
run "v210, -top 1 (input)"          c.mov  -top 1 -f yuv4mpegpipe -i in.y4m -c:v v210
run "v210, -top 0 (input)"          c0.mov -top 0 -f yuv4mpegpipe -i in.y4m -c:v v210
run "v210, -vf setfield=tff"        d.mov  -f yuv4mpegpipe -i in.y4m -vf setfield=tff -c:v v210
run "ProRes HQ, nothing"            e.mov  -f yuv4mpegpipe -i in.y4m -c:v prores_ks -profile:v 3
run "ProRes HQ, -top 1"             f.mov  -top 1 -f yuv4mpegpipe -i in.y4m -c:v prores_ks -profile:v 3
run "ProRes HQ, -top 1 +ildct"      g.mov  -top 1 -f yuv4mpegpipe -i in.y4m -flags +ildct -c:v prores_ks -profile:v 3
run "ProRes HQ, -top 0 +ildct"      g0.mov -top 0 -f yuv4mpegpipe -i in.y4m -flags +ildct -c:v prores_ks -profile:v 3

echo "== P4/P6: other containers with -top 1"
for ext in mkv avi; do
  "$FF" -v error -y -top 1 -f yuv4mpegpipe -i in.y4m -c:v v210 "top.$ext"
  echo "v210 .$ext field_order: $(fo "top.$ext")"
done
"$FF" -v error -y -f yuv4mpegpipe -i in.y4m -c:v v210 x.mp4 2>&1 | head -1 || true

echo "== P7: interlaced 4:2:0 -> 4:2:2. Field 0 chroma U=64, field 1 U=192."
cat > chroma.vpy <<'PY'
import os, vapoursynth as vs
core = vs.core
y = core.std.BlankClip(width=64, height=64, format=vs.GRAY8, color=128, length=4, fpsnum=25)
ua = core.std.BlankClip(width=32, height=16, format=vs.GRAY8, color=64, length=4, fpsnum=25)
ub = core.std.BlankClip(width=32, height=16, format=vs.GRAY8, color=192, length=4, fpsnum=25)
u = core.std.DoubleWeave(core.std.Interleave([ua, ub]), tff=True)[::2]  # row k = field k%2
v = core.std.BlankClip(u, color=128)
c = core.std.SetFieldBased(core.std.ShufflePlanes([y, u, v], [0, 0, 0], vs.YUV), 2)
if os.environ.get("FIELDAWARE"):
    c = core.resize.Bicubic(c, format=vs.YUV422P10)  # what the worker now does
c.set_output()
PY
"$VSPIPE" -c y4m chroma.vpy c420.y4m >/dev/null 2>&1
FIELDAWARE=1 "$VSPIPE" -c y4m chroma.vpy c422.y4m >/dev/null 2>&1
"$FF" -v error -y -top 1 -f yuv4mpegpipe -i c420.y4m -c:v v210 -pix_fmt yuv422p10le by_ffmpeg.mov
"$FF" -v error -y -f yuv4mpegpipe -i c422.y4m -c:v v210 by_script.mov
for f in by_ffmpeg.mov by_script.mov; do
  "$FF" -v error -i "$f" -frames:v 1 -f rawvideo -pix_fmt yuv422p10le - | python3 -c "
import sys, struct
d = sys.stdin.buffer.read(); W = 64; H = 64
u = d[W*H*2:]
rows = [struct.unpack_from('<H', u, (r*32+16)*2)[0] >> 2 for r in range(2, 12)]
print('$f U rows 2..11 (8-bit):', rows)"
done

echo "== P8: v210 data rate at 720x576 25p (ffmpeg's own figure)"
"$FF" -y -f yuv4mpegpipe -i in.y4m -c:v v210 rate.mov 2>&1 | grep 'Stream.*v210' | grep -o '[0-9]* kb/s'
python3 -c "print('formula: ceil(720/48)*128 bytes/line * 576 * 8 * 25 =', -(-720//48)*128*576*8*25, 'bit/s')"
