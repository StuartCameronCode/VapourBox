#!/bin/bash
# Reproduces every number in ../index.html.
#
#   SCRATCH=/some/scratch/dir [DEPS=deps/macos-arm64] [WORKER=...] ./reproduce.sh
#
# DEPS defaults to the repo's deps/macos-arm64; WORKER to the repo's debug
# build (cargo build). For the "before" column of the job table, point WORKER
# at a worker built from a commit before the fix (a7ba1ac or earlier, run from
# its own source tree so it finds that commit's templates).
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
for f in yuv420p9le yuv422p9le yuv444p9le gray9le yuv420p10le; do
  [ -f "src_$f.mkv" ] || q -i master.mkv -vf setfield=tff -c:v ffv1 -pix_fmt "$f" "src_$f.mkv"
done

echo; echo "== havsfunc paths at 9/10 bits, SD and HD (deps Python)"
PYTHONHOME="$D/python" PYTHONPATH="$D:$D/python-packages" PYTHONNOUSERSITE=1 \
  XDG_CONFIG_HOME="$D/config" "$D/python/bin/python3" "$HERE/haf_depths_9.py"

echo; echo "== real jobs, FFV1 output at the source's format, worker $W"
# name|processingPipeline JSON
JOBS=(
  'default|{"deinterlace":{"enabled":true,"tff":true}}'
  'yahr|{"deinterlace":{"enabled":false},"dehalo":{"enabled":true,"method":"YAHR"}}'
  'ctmf|{"deinterlace":{"enabled":false},"noiseReduction":{"enabled":true,"method":"ctmf","ctmfRadius":3}}'
)
for f in yuv420p10le yuv420p9le yuv422p9le gray9le; do
  for j in "${JOBS[@]}"; do
    name=${j%%|*}; pipe=${j#*|}
    qt=$([ "$name" = default ] && echo true || echo false)
    cat > "job_${f}_$name.json" <<JSON
{"id":"00000000-0000-0000-0000-000000000031","inputPath":"$S/src_$f.mkv",
 "outputPath":"$S/out_${f}_$name.mkv","qtgmcParameters":{"enabled":$qt,"tff":true},
 "processingPipeline":$pipe,
 "encodingSettings":{"codec":"ffv1","container":"mkv","audioMode":"none","chromaSubsampling":"original"},
 "inputPixelFormat":"$f","detectedFieldOrder":"tff",
 "inputFrameRate":25,"totalFrames":50,"inputWidth":352,"inputHeight":288}
JSON
    rm -f "out_${f}_$name.mkv"
    log=$("$W" --config "job_${f}_$name.json" 2>&1 || true)
    if [ -f "out_${f}_$name.mkv" ] && [ -s "out_${f}_$name.mkv" ]; then
      echo "$f $name: ok, $("$FP" -v error -count_frames -show_entries stream=pix_fmt,nb_read_frames -of csv=p=0 "out_${f}_$name.mkv")"
    else
      echo "$f $name: FAILED: $(grep -o 'CTMF: [^"\\.]*' <<<"$log" | head -1)"
    fi
  done
done

echo; echo "== decoder 9 -> 10: exact?"
q -i src_yuv444p9le.mkv -frames:v 1 -f rawvideo -pix_fmt yuv444p9le a9.raw
q -i src_yuv444p9le.mkv -frames:v 1 -f rawvideo -pix_fmt yuv444p10le a10.raw
python3 -I "$HERE/shift_check_9.py" a9.raw a10.raw "limited range"
q -i src_yuv444p9le.mkv -c:v ffv1 -color_range pc src_yuv444p9le_pc.mkv
q -i src_yuv444p9le_pc.mkv -frames:v 1 -f rawvideo -pix_fmt yuv444p9le a9pc.raw
q -i src_yuv444p9le_pc.mkv -frames:v 1 -f rawvideo -pix_fmt yuv444p10le a10pc.raw
python3 -I "$HERE/shift_check_9.py" a9pc.raw a10pc.raw "full range"

echo; echo "== what each encoder negotiates from a 9-bit vs a 10-bit 4:2:0 input"
for enc in libx264 libx265 libsvtav1 ffv1 ffvhuff; do
  row="$enc:"
  for f in yuv420p9le yuv420p10le; do
    q -i src_yuv420p9le.mkv -frames:v 5 -vf "format=$f" -c:v "$enc" "neg_$enc.mkv" 2>/dev/null \
      && row="$row $f -> $("$FP" -v error -show_entries stream=pix_fmt -of csv=p=0 "neg_$enc.mkv")" \
      || row="$row $f -> (encoder unavailable)"
  done
  echo "$row"
done

echo; echo "== FFV1 size, the 9-bit fixture stored at 9 vs 10 bits"
q -i src_yuv420p9le.mkv -c:v ffv1 -pix_fmt yuv420p9le size_9.mkv
q -i src_yuv420p9le.mkv -c:v ffv1 -pix_fmt yuv420p10le size_10.mkv
s9=$(stat -f %z size_9.mkv 2>/dev/null || stat -c %s size_9.mkv)
s10=$(stat -f %z size_10.mkv 2>/dev/null || stat -c %s size_10.mkv)
python3 -I -c "import sys; a,b=map(int,sys.argv[1:]); print(f'9-bit {a} bytes, 10-bit {b} bytes, +{(b/a-1)*100:.1f}%')" "$s9" "$s10"
