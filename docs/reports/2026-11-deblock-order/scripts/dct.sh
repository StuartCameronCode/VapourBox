#!/bin/bash
# The order comparison for DCTFilter (the third Deblock method, at the app's
# default curve), on the 1000 kbps fixtures. Added after the main run, when
# per-field deblocking was being built for all three methods.
# Writes $SCRATCH/results_dct.csv. Run run.sh first (it builds vhs_ref).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/../../../.."
S="${SCRATCH:?set SCRATCH to your scratch directory}"
FF=deps/macos-arm64/ffmpeg/ffmpeg
VSPIPE=deps/macos-arm64/vapoursynth/vspipe
CSV="$S/results_dct.csv"
echo "fixture,bitrate,deint,order,method,psnr_y,ssim_y,vmaf,blockiness" > "$CSV"
for fx in film vhs; do
  in="$S/fx/${fx}_1000.yuv"; nf=$(( $(stat -f %z "$in") / 622080 ))
  for d in 1 0; do
    if [ $d = 1 ]; then ref="$S/fx/${fx}_ref.yuv"; fps=50; orders="after woven field"
    else ref="$S/fx/${fx}_clean.yuv"; fps=25; orders="woven field"; fi
    for o in $orders; do
      out="$S/out/${fx}_1000_${o}_dct_d${d}.y4m"
      env TPL="$PWD/worker/templates" NF=$nf ORDER=$o METHOD=dct DEINT=$d \
        $VSPIPE -c y4m "$HERE/probe.vpy" "$out" < "$in" 2>"$out.log"
      m=$($FF -v info -i "$out" -f rawvideo -pix_fmt yuv420p -s 720x576 -framerate $fps -i "$ref" -lavfi \
         "[0:v]split[a0][a1];[1:v]split[b0][b1];[a0]extractplanes=y[ay];[b0]extractplanes=y[by];[ay][by]psnr[p];[p]nullsink;\
          [a1]extractplanes=y[a2];[b1]extractplanes=y[b2];[a2][b2]ssim" -f null - 2>&1)
      psnr=$(grep -oE 'PSNR y:[0-9.]+' <<<"$m" | head -1 | cut -d: -f2)
      ssim=$(grep -oE 'SSIM Y:[0-9.]+' <<<"$m" | head -1 | cut -d: -f2)
      blk=$($FF -v error -i "$out" -vf blockdetect,metadata=print:file=- -f null - 2>/dev/null \
            | grep 'block=' | awk -F= '{s+=$2;n++} END {printf "%.3f", s/n}')
      echo "$fx,1000,$d,$o,dct,$psnr,$ssim,,$blk" | tee -a "$CSV"
    done
  done
done
