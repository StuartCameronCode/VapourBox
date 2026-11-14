#!/bin/bash
# Reproduces every number in ../index.html.
#
#   SCRATCH=/some/scratch/dir [DEPS=deps/macos-arm64] [WORKER=...] ./reproduce.sh
#
# DEPS defaults to the repo's deps/macos-arm64; WORKER to the repo's debug
# build (cargo build). For the "before" column of the job table, point WORKER
# at a worker built from a commit before the fix (efedef0 or earlier).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
S="${SCRATCH:?set SCRATCH to your scratch directory}"
D="$(cd "${DEPS:-$REPO/deps/macos-arm64}" && pwd)"
W="${WORKER:-$REPO/worker/target/debug/vapourbox-worker}"
FF="$D/ffmpeg/ffmpeg"; FP="$D/ffmpeg/ffprobe"
mkdir -p "$S"; cd "$S"
q() { "$FF" -hide_banner -loglevel error -y "$@"; }

echo "== fixtures: one degraded interlaced MPEG-2 master, losslessly at each format"
[ -f master.mkv ] || q -f lavfi -i testsrc2=size=352x288:rate=25:duration=2 \
  -vf 'noise=alls=18:allf=t+u:all_seed=20260805,setfield=tff' \
  -c:v mpeg2video -b:v 700k -flags +ilme+ildct -g 15 -bf 2 master.mkv
for f in yuv420p12le yuv420p14le gray14le gbrp14le yuv444p14le yuv420p16le; do
  [ -f "src_$f.mkv" ] || q -i master.mkv -vf setfield=tff -c:v ffv1 -pix_fmt "$f" "src_$f.mkv"
done

echo; echo "== havsfunc functions at 9/12/14/16 bits (deps Python)"
PYTHONHOME="$D/python" PYTHONPATH="$D:$D/python-packages" PYTHONNOUSERSITE=1 \
  XDG_CONFIG_HOME="$D/config" "$D/python/bin/python3" "$HERE/haf_depths.py"

echo; echo "== real jobs: default pipeline (QTGMC, TFF), x264, worker $W"
for f in yuv420p12le yuv420p14le gray14le gbrp14le; do
  cat > "job_$f.json" <<JSON
{"id":"00000000-0000-0000-0000-000000000023","inputPath":"$S/src_$f.mkv",
 "outputPath":"$S/out_$f.mkv","qtgmcParameters":{"enabled":true,"tff":true},
 "encodingSettings":{},"inputPixelFormat":"$f","detectedFieldOrder":"tff",
 "inputFrameRate":25,"totalFrames":50,"inputWidth":352,"inputHeight":288}
JSON
  rm -f "out_$f.mkv"
  log=$("$W" --config "job_$f.json" 2>&1 || true)
  if [ -f "out_$f.mkv" ]; then
    echo "$f: ok, $("$FP" -v error -count_frames -show_entries stream=nb_read_frames,pix_fmt -of csv=p=0 "out_$f.mkv")"
  else
    echo "$f: FAILED: $(grep -o 'bitdepth: [^"\\]*' <<<"$log" | head -1) / $(grep -o '"message":"[^"]*' <<<"$log" | tail -1)"
  fi
done

echo; echo "== decoder 14 -> 16: exact?"
q -i src_yuv444p14le.mkv -frames:v 1 -f rawvideo -pix_fmt yuv444p14le a14.raw
q -i src_yuv444p14le.mkv -frames:v 1 -f rawvideo -pix_fmt yuv444p16le a16.raw
python3 -I "$HERE/shift_check.py" a14.raw a16.raw "limited range"
q -i src_yuv444p14le.mkv -c:v ffv1 -color_range pc src_yuv444p14le_pc.mkv
q -i src_yuv444p14le_pc.mkv -frames:v 1 -f rawvideo -pix_fmt yuv444p14le a14pc.raw
q -i src_yuv444p14le_pc.mkv -frames:v 1 -f rawvideo -pix_fmt yuv444p16le a16pc.raw
python3 -I "$HERE/shift_check.py" a14pc.raw a16pc.raw "full range"

echo; echo "== what each encoder negotiates from a 14-bit vs a 16-bit 4:2:0 input"
for enc in libx264 libx265 libsvtav1 ffv1 ffvhuff; do
  row="$enc:"
  for f in yuv420p14le yuv420p16le; do
    q -i src_yuv420p14le.mkv -frames:v 5 -vf "format=$f" -c:v "$enc" "neg_$enc.mkv" 2>/dev/null \
      && row="$row $f -> $("$FP" -v error -show_entries stream=pix_fmt -of csv=p=0 "neg_$enc.mkv")" \
      || row="$row $f -> (encoder unavailable)"
  done
  echo "$row"
done

echo; echo "== FFV1 size, the 14-bit fixture stored at 14 vs 16 bits"
q -i src_yuv420p14le.mkv -c:v ffv1 -pix_fmt yuv420p14le size_14.mkv
q -i src_yuv420p14le.mkv -c:v ffv1 -pix_fmt yuv420p16le size_16.mkv
s14=$(stat -f %z size_14.mkv 2>/dev/null || stat -c %s size_14.mkv)
s16=$(stat -f %z size_16.mkv 2>/dev/null || stat -c %s size_16.mkv)
python3 -I -c "import sys; a,b=map(int,sys.argv[1:]); print(f'14-bit {a} bytes, 16-bit {b} bytes, +{(b/a-1)*100:.1f}%')" "$s14" "$s16"
