#!/bin/bash
# The order comparison again at a much stronger Deblock_QED setting
# (quant1=36, quant2=44, against the app's 24/26), on the 1000 kbps fixtures,
# to see whether order starts to matter once the deblocker is doing more.
# Appends to $SCRATCH/results_strong.csv. Run run.sh first (it builds vhs_ref).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/../../../.."
S="${SCRATCH:?set SCRATCH to your scratch directory}"
FF=deps/macos-arm64/ffmpeg/ffmpeg
VSPIPE=deps/macos-arm64/vapoursynth/vspipe
CSV="$S/results_strong.csv"
echo "fixture,bitrate,deint,order,method,psnr_y,ssim_y,vmaf,blockiness" > "$CSV"
for fx in film vhs; do
  in="$S/fx/${fx}_1000.yuv"; nf=$(( $(stat -f %z "$in") / 622080 ))
  for d in 1 0; do
    if [ $d = 1 ]; then ref="$S/fx/${fx}_ref.yuv"; fps=50; orders="after woven field"
    else ref="$S/fx/${fx}_clean.yuv"; fps=25; orders="woven field"; fi
    for o in $orders; do
      out="$S/out/${fx}_1000_${o}_qedstrong_d${d}.y4m"
      env TPL="$PWD/worker/templates" NF=$nf ORDER=$o METHOD=qed DEINT=$d Q1=36 Q2=44 \
        $VSPIPE -c y4m "$HERE/probe.vpy" "$out" < "$in" 2>"$out.log"
      m=$($FF -v info -i "$out" -f rawvideo -pix_fmt yuv420p -s 720x576 -framerate $fps -i "$ref" -lavfi \
         "[0:v]split[a0][a1];[1:v]split[b0][b1];[a0]extractplanes=y[ay];[b0]extractplanes=y[by];[ay][by]psnr[p];[p]nullsink;\
          [a1]extractplanes=y[a2];[b1]extractplanes=y[b2];[a2][b2]ssim" -f null - 2>&1)
      psnr=$(grep -oE 'PSNR y:[0-9.]+' <<<"$m" | head -1 | cut -d: -f2)
      ssim=$(grep -oE 'SSIM Y:[0-9.]+' <<<"$m" | head -1 | cut -d: -f2)
      blk=$($FF -v error -i "$out" -vf blockdetect,metadata=print:file=- -f null - 2>/dev/null \
            | grep 'block=' | awk -F= '{s+=$2;n++} END {printf "%.3f", s/n}')
      echo "$fx,1000,$d,$o,qed-36/44,$psnr,$ssim,,$blk" | tee -a "$CSV"
    done
  done
done
