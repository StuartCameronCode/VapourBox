#!/bin/bash
# The report's screenshots, from the fixtures in $SCRATCH/fx (build_fixtures.py).
# Each is a row of same-size crops at 3x nearest-neighbour, left to right as
# the report's caption lists them. Labels are in the captions, not the pixels.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
S="${SCRATCH:?set SCRATCH to your scratch directory}"
FF="${FFMPEG:-$HERE/../../../../deps/macos-arm64/ffmpeg/ffmpeg}"
IMG="$HERE/../img"
mkdir -p "$IMG" "$S/crops"

# crop <fixture> <x> <y> <w> <h> <out>: frame 2, luma only, 3x.
crop() {
  "$FF" -v error -y -i "$S/fx/$1.mkv" \
    -vf "select=eq(n\,2),crop=$4:$5:$2:$3,extractplanes=y,scale=iw*3:ih*3:flags=neighbor" \
    -frames:v 1 "$6"
}
row() { # row <out> <inputs...>
  local out=$1; shift
  local args=() n=0
  for f in "$@"; do args+=(-i "$f"); n=$((n + 1)); done
  "$FF" -v error -y "${args[@]}" -filter_complex "hstack=inputs=$n" "$out"
}

# 1. Noise: clean, white sigma 4, tape-like sigma 6, synthetic grain sigma 6.
for f in kodak23_clean kodak23_n4 kodak23_tape6 kodak23_grain6; do
  crop $f 300 60 110 110 "$S/crops/$f.png"
done
row "$IMG/01-noise-kinds.png" "$S"/crops/kodak23_{clean,n4,tape6,grain6}.png

# 2. Halos: clean, USM radius 1 amount 1, radius 2 amount 1, line peaking 2/1.
for f in kodak08_clean kodak08_usm1_1 kodak08_usm2_1 kodak08_peak2_1; do
  crop $f 250 150 110 110 "$S/crops/$f.png"
done
row "$IMG/02-halo-kinds.png" "$S"/crops/kodak08_{clean,usm1_1,usm2_1,peak2_1}.png

# 3. Animation: outlines (one-sided) against sharpened outlines (two-sided).
for f in cel_clean cel_usm1_1; do
  crop $f 120 140 140 110 "$S/crops/$f.png"
done
row "$IMG/03-cel-outline.png" "$S"/crops/cel_{clean,usm1_1}.png

# 4. Real footage: VHS capture, Night of the Living Dead grain, NASA 1080p.
crop real_vhs 330 120 150 110 "$S/crops/real_vhs.png"
crop real_notld_car 560 300 150 110 "$S/crops/real_notld_car.png"
crop real_nasa_mc 900 400 150 110 "$S/crops/real_nasa_mc.png"
row "$IMG/04-real.png" "$S"/crops/real_{vhs,notld_car,nasa_mc}.png
ls -la "$IMG"
