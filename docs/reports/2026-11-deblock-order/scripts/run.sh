#!/bin/bash
# Runs every variant of the deblock-order probe over the fixtures built by
# make_fixtures.sh and writes $SCRATCH/results.csv.
#
# Reference each output is scored against:
#   deinterlaced, film - the true 50p frames (film_ref.yuv)
#   deinterlaced, vhs  - QTGMC Slower of the lossless capture (no true 50p exists)
#   left interlaced    - the clean interlaced frames before MPEG-2 (<fx>_clean.yuv)
#
# Metrics, all luma except VMAF: PSNR, SSIM, VMAF (libvmaf default model) and
# ffmpeg's blockdetect (mean per-frame blockiness of the output; lower = fewer
# visible 8x8 edges, measured on the output's own 8-pixel grid).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/../../../.."
S="${SCRATCH:?set SCRATCH to your scratch directory}"
FF=deps/macos-arm64/ffmpeg/ffmpeg
VSPIPE=deps/macos-arm64/vapoursynth/vspipe
RATES="${RATES:-1000 1500 3000}"
TPL="$PWD/worker/templates"
mkdir -p "$S/out"

frames() { echo $(( $(stat -f %z "$1") / 622080 )); }   # 720*576*1.5

# score OUT.y4m REF.yuv FPS -> "psnr,ssim,vmaf,block"
score() {
  local m
  m=$($FF -v info -i "$1" -f rawvideo -pix_fmt yuv420p -s 720x576 -framerate "$3" -i "$2" -lavfi \
     "[0:v]split=3[a0][a1][a2];[1:v]split=3[b0][b1][b2];\
      [a0]extractplanes=y[ay];[b0]extractplanes=y[by];[ay][by]psnr[p];[p]nullsink;\
      [a1]extractplanes=y[ay2];[b1]extractplanes=y[by2];[ay2][by2]ssim[s];[s]nullsink;\
      [a2][b2]libvmaf=n_threads=8" -f null - 2>&1)
  local psnr ssim vmaf blk
  psnr=$(grep -oE 'PSNR y:[0-9.inf]+' <<<"$m" | head -1 | cut -d: -f2)
  ssim=$(grep -oE 'SSIM Y:[0-9.]+' <<<"$m" | head -1 | cut -d: -f2)
  vmaf=$(grep -oE 'VMAF score: [0-9.]+' <<<"$m" | head -1 | awk '{print $3}')
  blk=$($FF -v error -i "$1" -vf blockdetect,metadata=print:file=- -f null - 2>/dev/null \
        | grep 'block=' | awk -F= '{s+=$2;n++} END {printf "%.3f", s/n}')
  echo "$psnr,$ssim,$vmaf,$blk"
}

# run IN.yuv OUT.y4m ORDER METHOD DEINT
run() {
  env TPL="$TPL" NF=$(frames "$1") ORDER=$3 METHOD=$4 DEINT=$5 \
    $VSPIPE -c y4m "$HERE/probe.vpy" "$2" < "$1" 2>"$2.log" \
    || { echo "FAILED: $2" >&2; tail -5 "$2.log" >&2; exit 1; }
}

# The vhs deinterlaced reference: QTGMC of the lossless capture.
run "$S/fx/vhs_clean.yuv" "$S/out/vhs_clean_ref.y4m" none qed 1
$FF -v error -y -i "$S/out/vhs_clean_ref.y4m" -f rawvideo -pix_fmt yuv420p "$S/fx/vhs_ref.yuv"

CSV="$S/results.csv"
echo "fixture,bitrate,deint,order,method,psnr_y,ssim_y,vmaf,blockiness" > "$CSV"

for fx in film vhs; do
  # Upper bound: the uncompressed interlaced source, deinterlaced.
  run "$S/fx/${fx}_clean.yuv" "$S/out/${fx}_clean_none_d1.y4m" none qed 1
  echo "$fx,clean,1,none,-,$(score "$S/out/${fx}_clean_none_d1.y4m" "$S/fx/${fx}_ref.yuv" 50)" | tee -a "$CSV"
  for r in $RATES; do
    in="$S/fx/${fx}_${r}.yuv"
    for d in 1 0; do
      if [ $d = 1 ]; then ref="$S/fx/${fx}_ref.yuv"; fps=50; orders="none after woven field"
      else ref="$S/fx/${fx}_clean.yuv"; fps=25; orders="none woven field"; fi
      for o in $orders; do
        for m in qed simple; do
          [ $o = none ] && [ $m = simple ] && continue
          out="$S/out/${fx}_${r}_${o}_${m}_d${d}.y4m"
          run "$in" "$out" $o $m $d
          echo "$fx,$r,$d,$o,$([ $o = none ] && echo - || echo $m),$(score "$out" "$ref" $fps)" | tee -a "$CSV"
        done
      done
    done
  done
done
