#!/bin/bash
# Reproduces every number in ../index.html: what -movflags +faststart costs on
# a ProRes HQ 1080p MOV (F1), how much disk it needs while it runs (F2), and
# that PCM restored audio muxes beside ProRes in MOV (F3).
#
#   SCRATCH=/some/scratch/dir ./probe.sh
#
# Uses the repo's deps bundle (deps/<platform>, or $DEPS). Writes only under
# $SCRATCH; needs ~9 GB free there. The 3-minute source (~4.3 GB) is reused
# if $SCRATCH/src.mov already exists, since encoding it takes ~8 minutes.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
S="${SCRATCH:?set SCRATCH to your scratch directory}"
DEPS="${DEPS:-$REPO/deps/macos-arm64}"
FF="$DEPS/ffmpeg/ffmpeg"; FP="$DEPS/ffmpeg/ffprobe"
RUNS="${RUNS:-3}"
mkdir -p "$S/out"; cd "$S"
now() { python3 -c 'import time; print(time.time())'; }

"$FF" -version | head -1
if [ ! -f src.mov ]; then
  echo "== building the source: 180 s of 1080p25 ProRes HQ, temporal noise for a realistic data rate"
  "$FF" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=s=1920x1080:r=25:d=180,noise=alls=20:allf=t+u,format=yuv422p10le" \
    -c:v prores_ks -profile:v 3 -f mov src.mov
fi
"$FP" -v error -show_entries format=size,bit_rate,duration -of default=nw=1 src.mov

echo "== F1: the same mux (-c copy) without and with +faststart, $RUNS runs"
printf '%-4s %12s %12s %10s\n' run none_s faststart_s extra_s
for i in $(seq "$RUNS"); do
  rm -f out/a.mov; t0=$(now); "$FF" -hide_banner -loglevel error -y -i src.mov -map 0 -c copy out/a.mov; t1=$(now)
  rm -f out/a.mov; t2=$(now); "$FF" -hide_banner -loglevel error -y -i src.mov -map 0 -c copy -movflags +faststart out/a.mov; t3=$(now)
  python3 -c "a=$t1-$t0; b=$t3-$t2; print(f'{$i:<4} {a:12.2f} {b:12.2f} {b-a:10.2f}')"
done
rm -f out/a.mov

echo "== F2: peak disk use in the output directory during a +faststart mux"
"$FF" -hide_banner -loglevel verbose -y -i src.mov -map 0 -c copy -movflags +faststart out/a.mov 2> fs.log &
pid=$!; peak=0; files=0
while kill -0 "$pid" 2>/dev/null; do
  k=$(du -sk out | cut -f1); [ "$k" -gt "$peak" ] && peak=$k
  n=$(ls out | wc -l | tr -d ' '); [ "$n" -gt "$files" ] && files=$n
done
wait "$pid"
echo "peak KiB: $peak   most files at once: $files   final bytes: $(stat -f %z out/a.mov 2>/dev/null || stat -c %s out/a.mov)"
grep -o "Starting second pass.*" fs.log || true
rm -f out/a.mov

echo "== F3: ProRes + pcm_s16le in MOV (what a restored track under Passthrough becomes)"
"$FF" -hide_banner -loglevel error -y -t 2 -i src.mov -f lavfi -t 2 -i "sine=f=440:r=48000" \
  -map 0:v -map 1:a -c:v copy -c:a pcm_s16le out/pcm.mov
"$FP" -v error -show_entries stream=codec_name,codec_tag_string,bit_rate -of csv=p=0 out/pcm.mov
rm -f out/pcm.mov
