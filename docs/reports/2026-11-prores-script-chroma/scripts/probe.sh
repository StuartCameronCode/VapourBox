#!/bin/bash
# Reproduces every number in ../index.html: ProRes's chroma conversion done by
# FFmpeg's -pix_fmt (OLD) against the script's CHROMA_CONVERT block (NEW).
#
#   SCRATCH=/some/scratch/dir ./probe.sh
#
# Uses the repo's deps bundle (deps/<platform>, or $DEPS). Writes only under
# $SCRATCH. Takes a few minutes: planes.py is plain Python.
#
# OLD is what the worker did before: the script leaves the format alone (or
# converts to the user's Color Format selection) and ffmpeg's -pix_fmt pin
# makes the profile's format. NEW is what it does now: the script converts to
# the profile's format itself, with _FieldBased set when the clip is still
# interlaced, and the pin is a no-op.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
S="${SCRATCH:?set SCRATCH to your scratch directory}"
DEPS="${DEPS:-$REPO/deps/macos-arm64}"
FF="$DEPS/ffmpeg/ffmpeg"; VSPIPE="$DEPS/vapoursynth/vspipe"
PY="python3 $HERE/planes.py"
RES="$REPO/Tests/TestResources"
export TEMPLATES="$REPO/worker/templates"
mkdir -p "$S"; cd "$S"

# decode SRC OUT PIXFMT FRAMES — the full stored frame, as the worker decodes it
# The setparams clears the 4444 fixture's `reserved` primaries/transfer (which
# FFmpeg 9's scaler refuses), as the worker's decoder does; untagged elsewhere.
decode() { "$FF" -v error -y -apply_cropping codec -i "$1" -frames:v "$4" -map 0:v:0 \
             -vf setparams=color_primaries=unknown:color_trc=unknown \
             -f rawvideo -pix_fmt "$3" "$2"; }

# pipe IN.raw PIXFMT W H N FB CONVERT TARGET_PIXFMT OUT [ffmpeg output args...]
#   FB / CONVERT may be "" (progressive / leave the format alone).
#   With no output args the result is raw TARGET_PIXFMT; otherwise they replace
#   "-f rawvideo" (e.g. a ProRes encode).
pipe() {
  local in="$1" pf="$2" w="$3" h="$4" n="$5" fb="$6" conv="$7" tgt="$8" out="$9"
  shift 9
  local top=(); [ -n "$fb" ] && top=(-top $([ "$fb" = 2 ] && echo 1 || echo 0))
  local outargs=(-f rawvideo); [ $# -gt 0 ] && outargs=("$@")
  W=$w H=$h N=$n PIXFMT=$pf FB=$fb CONVERT=$conv \
    "$VSPIPE" -c y4m "$HERE/convert.vpy" - < "$in" 2>/dev/null \
    | "$FF" -v error -y ${top[@]+"${top[@]}"} -f yuv4mpegpipe -i - -pix_fmt "$tgt" "${outargs[@]}" "$out"
}
back() { "$FF" -v error -y -i "$1" -f rawvideo -pix_fmt "$3" "$2"; }   # decode an encode
hash() { if command -v md5 >/dev/null; then md5 -q "$1"; else md5sum "$1" | cut -d" " -f1; fi; }

echo "== M1: synthetic interlaced 4:2:0, top field red, bottom blue (the heavy test's fixture)"
"$FF" -v error -y -f lavfi -i color=c=red:size=720x288:rate=50:duration=0.2 \
  -f lavfi -i color=c=blue:size=720x288:rate=50:duration=0.2 \
  -filter_complex '[0:v]format=yuv420p[a];[1:v]format=yuv420p[b];[a][b]interleave,tinterlace=mode=merge,setfield=tff[v]' \
  -map '[v]' -f rawvideo -pix_fmt yuv420p m1.raw
echo "source U, chroma rows 50..55 (8-bit): $($PY rows m1.raw 720 576 yuv420p U 180 50 56)"
pipe m1.raw yuv420p 720 576 5 2 ""        yuv422p10le m1_old.raw
pipe m1.raw yuv420p 720 576 5 2 YUV422P10 yuv422p10le m1_new.raw
echo "OLD 4:2:2 U rows 100..111 (10-bit): $($PY rows m1_old.raw 720 576 yuv422p10le U 180 100 112)"
echo "NEW 4:2:2 U rows 100..111 (10-bit): $($PY rows m1_new.raw 720 576 yuv422p10le U 180 100 112)"
pipe m1.raw yuv420p 720 576 5 2 ""        yuv444p10le m1_old444.raw
pipe m1.raw yuv420p 720 576 5 2 YUV444P10 yuv444p10le m1_new444.raw
echo "OLD 4:4:4 U rows 100..111 (10-bit): $($PY rows m1_old444.raw 720 576 yuv444p10le U 360 100 112)"
echo "NEW 4:4:4 U rows 100..111 (10-bit): $($PY rows m1_new444.raw 720 576 yuv444p10le U 360 100 112)"
echo "-- after the ProRes encoder (+ildct, as the worker does for interlaced output)"
for prof in 0 3 4; do
  t=yuv422p10le; c=YUV422P10; col=180; [ $prof -ge 4 ] && { t=yuv444p10le; c=YUV444P10; col=360; }
  pipe m1.raw yuv420p 720 576 5 2 ""  $t m1_old_p$prof.mov -flags +ildct -c:v prores_ks -profile:v $prof
  pipe m1.raw yuv420p 720 576 5 2 $c  $t m1_new_p$prof.mov -flags +ildct -c:v prores_ks -profile:v $prof
  back m1_old_p$prof.mov m1_old_p$prof.raw $t; back m1_new_p$prof.mov m1_new_p$prof.raw $t
  echo "profile $prof OLD U rows 100..111: $($PY rows m1_old_p$prof.raw 720 576 $t U $col 100 112)"
  echo "profile $prof NEW U rows 100..111: $($PY rows m1_new_p$prof.raw 720 576 $t U $col 100 112)"
done

echo "== M2a: interlaced ground truth. interlaced_test.avi (4:2:2) -> 4:2:0 with MPEG-2 field siting -> back to 4:2:2"
decode "$RES/interlaced_test.avi" gt_i422.raw yuv422p10le 5
$PY down gt_i422.raw src_i420.raw 720 576 yuv422p10le i420
pipe src_i420.raw yuv420p10le 720 576 5 2 ""        yuv422p10le m2_old.raw
pipe src_i420.raw yuv420p10le 720 576 5 2 YUV422P10 yuv422p10le m2_new.raw
pipe src_i420.raw yuv420p10le 720 576 5 "" YUV422P10 yuv422p10le m2_new_unmarked.raw
echo "OLD (ffmpeg -pix_fmt) against the 4:2:2 original:"; $PY cmp m2_old.raw gt_i422.raw 720 576 yuv422p10le UV
echo "NEW (script, _FieldBased=2) against the 4:2:2 original:"; $PY cmp m2_new.raw gt_i422.raw 720 576 yuv422p10le UV
echo "NEW but not marked interlaced (field order not detected):"; $PY cmp m2_new_unmarked.raw gt_i422.raw 720 576 yuv422p10le UV
echo "-- the same through ProRes 422 HQ (+ildct)"
pipe src_i420.raw yuv420p10le 720 576 5 2 ""        yuv422p10le m2_old.mov -flags +ildct -c:v prores_ks -profile:v 3
pipe src_i420.raw yuv420p10le 720 576 5 2 YUV422P10 yuv422p10le m2_new.mov -flags +ildct -c:v prores_ks -profile:v 3
back m2_old.mov m2_old_hq.raw yuv422p10le; back m2_new.mov m2_new_hq.raw yuv422p10le
echo "OLD:"; $PY cmp m2_old_hq.raw gt_i422.raw 720 576 yuv422p10le UV
echo "NEW:"; $PY cmp m2_new_hq.raw gt_i422.raw 720 576 yuv422p10le UV

echo "== M2b: real interlaced 4:2:0, pal-dvbt-fieldcoded-25i.ts (no ground truth: OLD vs NEW)"
decode "$RES/pal-dvbt-fieldcoded-25i.ts" dvbt.raw yuv420p 5
pipe dvbt.raw yuv420p 720 576 5 2 ""        yuv422p10le m2b_old.raw
pipe dvbt.raw yuv420p 720 576 5 2 YUV422P10 yuv422p10le m2b_new.raw
$PY cmp m2b_old.raw m2b_new.raw 720 576 yuv422p10le UV

echo "== M3a: progressive ground truth. pal-sd-25.mov (4:2:2 10-bit) -> 4:2:0 -> back to 4:2:2"
decode "$RES/pal-sd-25.mov" gt_p422.raw yuv422p10le 5
$PY down gt_p422.raw src_p420.raw 720 576 yuv422p10le p420
pipe src_p420.raw yuv420p10le 720 576 5 "" ""        yuv422p10le m3_old.raw
pipe src_p420.raw yuv420p10le 720 576 5 "" YUV422P10 yuv422p10le m3_new.raw
echo "OLD:"; $PY cmp m3_old.raw gt_p422.raw 720 576 yuv422p10le UV
echo "NEW:"; $PY cmp m3_new.raw gt_p422.raw 720 576 yuv422p10le UV
echo "OLD vs NEW:"; $PY cmp m3_old.raw m3_new.raw 720 576 yuv422p10le UV

echo "== M3b/M5: progressive 4:4:4 ground truth. reserved_colour_tags_4444a.mov (4:4:4) -> 4:2:0 / 4:2:2 -> back to 4:4:4"
decode "$RES/reserved_colour_tags_4444a.mov" gt_444.raw yuv444p10le 10
$PY down gt_444.raw src_444_420.raw 320 240 yuv444p10le p420h
$PY down gt_444.raw src_444_422.raw 320 240 yuv444p10le h422
# down writes the subsampled planes; the files are now 4:2:0 / 4:2:2 10-bit.
for s in 420 422; do
  pipe src_444_$s.raw yuv${s}p10le 320 240 10 "" ""        yuv444p10le m3b_old_$s.raw
  pipe src_444_$s.raw yuv${s}p10le 320 240 10 "" YUV444P10 yuv444p10le m3b_new_$s.raw
  echo "4:2:${s:2} -> 4:4:4 OLD:"; $PY cmp m3b_old_$s.raw gt_444.raw 320 240 yuv444p10le UV
  echo "4:2:${s:2} -> 4:4:4 NEW:"; $PY cmp m3b_new_$s.raw gt_444.raw 320 240 yuv444p10le UV
done
echo "-- pal-sd-25.mov 4:2:2 -> 4:4:4 (ProRes 4444 from a ProRes 422 source), OLD vs NEW"
pipe gt_p422.raw yuv422p10le 720 576 5 "" ""        yuv444p10le m5_old.raw
pipe gt_p422.raw yuv422p10le 720 576 5 "" YUV444P10 yuv444p10le m5_new.raw
$PY cmp m5_old.raw m5_new.raw 720 576 yuv444p10le UV

echo "== M4: a source already in the profile's format is untouched"
pipe gt_p422.raw yuv422p10le 720 576 5 "" ""        yuv422p10le m4_old.raw
pipe gt_p422.raw yuv422p10le 720 576 5 "" YUV422P10 yuv422p10le m4_new.raw
echo "raw: OLD $(hash m4_old.raw)  NEW $(hash m4_new.raw)  source $(hash gt_p422.raw)"
pipe gt_p422.raw yuv422p10le 720 576 5 "" ""        yuv422p10le m4_old.mov -c:v prores_ks -profile:v 3
pipe gt_p422.raw yuv422p10le 720 576 5 "" YUV422P10 yuv422p10le m4_new.mov -c:v prores_ks -profile:v 3
back m4_old.mov m4_old_hq.raw yuv422p10le; back m4_new.mov m4_new_hq.raw yuv422p10le
echo "ProRes HQ decoded: OLD $(hash m4_old_hq.raw)  NEW $(hash m4_new_hq.raw)"

echo "== M6: deeper than 10 bits -> 10 bits"
decode "$RES/reserved_colour_tags_4444a.mov" src_444_12.raw yuv444p12le 10
pipe src_444_12.raw yuv444p12le 320 240 10 "" ""        yuv444p10le m6_old12.raw
pipe src_444_12.raw yuv444p12le 320 240 10 "" YUV444P10 yuv444p10le m6_new12.raw
echo "12-bit ProRes 4444 -> 10-bit 4:4:4 OLD:"; $PY cmpref m6_old12.raw yuv444p10le src_444_12.raw yuv444p12le 320 240
echo "12-bit ProRes 4444 -> 10-bit 4:4:4 NEW:"; $PY cmpref m6_new12.raw yuv444p10le src_444_12.raw yuv444p12le 320 240
$PY gen16 src_16.raw 720 576 3
pipe src_16.raw yuv422p16le 720 576 3 "" ""        yuv422p10le m6_old16.raw
pipe src_16.raw yuv422p16le 720 576 3 "" YUV422P10 yuv422p10le m6_new16.raw
echo "16-bit 4:2:2 gradient -> 10-bit OLD:"; $PY cmpref m6_old16.raw yuv422p10le src_16.raw yuv422p16le 720 576
echo "16-bit 4:2:2 gradient -> 10-bit NEW:"; $PY cmpref m6_new16.raw yuv422p10le src_16.raw yuv422p16le 720 576

echo "== M7: an 8-bit Color Format selection (4:2:0 8-bit) on a deeper source, into ProRes 422 HQ"
# The 16-bit gradient from M6: real precision below 8 bits, which pal-sd-25.mov
# does not have (its luma is 8-bit content: every sample a multiple of 4).
pipe src_16.raw yuv422p16le 720 576 3 "" YUV420P8  yuv422p10le m7_old.raw
pipe src_16.raw yuv422p16le 720 576 3 "" YUV422P10 yuv422p10le m7_new.raw
echo "pal-sd-25.mov: $($PY fine gt_p422.raw 720 576 yuv422p10le)"
echo "OLD (4:2:0 8-bit in the script, padded to 10 by ffmpeg): $($PY fine m7_old.raw 720 576 yuv422p10le)"
$PY cmpref m7_old.raw yuv422p10le src_16.raw yuv422p16le 720 576
echo "NEW (10-bit 4:2:2 in the script):                        $($PY fine m7_new.raw 720 576 yuv422p10le)"
$PY cmpref m7_new.raw yuv422p10le src_16.raw yuv422p16le 720 576

echo "== Figure: the DVB-T frame's worst chroma block, OLD | NEW"
read -r HX HY <<< "$($PY hotspot m2b_old.raw m2b_new.raw 720 576 yuv422p10le 48)"
echo "largest OLD/NEW difference: chroma block at x=$HX y=$HY (picture x=$((HX * 2)))"
for run in old new; do
  "$FF" -v error -y -f rawvideo -pix_fmt yuv422p10le -s 720x576 -i m2b_$run.raw -frames:v 1 \
    -vf "crop=96:48:$((HX * 2)):$HY,scale=384:192:flags=neighbor,format=rgb24" crop_$run.png
  "$FF" -v error -y -f rawvideo -pix_fmt yuv422p10le -s 720x576 -i m2b_$run.raw -frames:v 1 \
    -vf "extractplanes=u,crop=48:48:$HX:$HY,scale=192:192:flags=neighbor,format=gray" u_$run.png
done
mkdir -p "$HERE/../img"
"$FF" -v error -y -i crop_old.png -i crop_new.png -filter_complex "[0][1]hstack=inputs=2" "$HERE/../img/1-dvbt-picture-old-new.png"
"$FF" -v error -y -i u_old.png -i u_new.png -filter_complex "[0][1]hstack=inputs=2" "$HERE/../img/2-dvbt-u-plane-old-new.png"

echo "== M8: speed, 1080i 4:2:0, 100 frames, into ProRes 422 HQ"
"$FF" -v error -y -f lavfi -i testsrc2=size=1920x1080:rate=25:duration=4 -f rawvideo -pix_fmt yuv420p m8.raw
for run in old new; do
  conv=""; [ $run = new ] && conv=YUV422P10
  start=$(python3 -c 'import time; print(time.time())')
  pipe m8.raw yuv420p 1920 1080 100 2 "$conv" yuv422p10le m8_$run.mov -flags +ildct -c:v prores_ks -profile:v 3
  end=$(python3 -c 'import time; print(time.time())')
  python3 -c "print('$run: %.2f s for 100 frames (%.1f fps)' % ($end - $start, 100 / ($end - $start)))"
done
