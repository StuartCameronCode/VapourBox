#!/bin/bash
# Renders the report's images from run.sh's outputs into ../img.
# All crops are 3x nearest-neighbour, so every pixel shown is a real one.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/../../../.."
S="${SCRATCH:?set SCRATCH to your scratch directory}"
FF="deps/macos-arm64/ffmpeg/ffmpeg -v error -y"
IMG="$HERE/../img"
mkdir -p "$IMG"
REFOPTS="-f rawvideo -pix_fmt yuv420p -s 720x576"

# order_strip FIXTURE RATE FRAME CROP OUT [EXTRA_FILTER]
# Panels: reference | no deblock | after QTGMC | woven, before | per field, before
order_strip() {
  local C="select=eq(n\,$3),crop=$4,scale=iw*3:ih*3:flags=neighbor${6:+,$6}"
  $FF $REFOPTS -framerate 50 -i "$S/fx/$1_ref.yuv" \
      -i "$S/out/$1_$2_none_qed_d1.y4m" -i "$S/out/$1_$2_after_qed_d1.y4m" \
      -i "$S/out/$1_$2_woven_qed_d1.y4m" -i "$S/out/$1_$2_field_qed_d1.y4m" \
      -filter_complex "[0:v]$C[a];[1:v]$C[b];[2:v]$C[c];[3:v]$C[d];[4:v]$C[e];[a][b][c][d][e]hstack=5" \
      -frames:v 1 "$5"
}

# 01: the decoded MPEG-2 input, woven, beside the clean interlaced frame
C1="select=eq(n\,51),crop=240:192:120:0,scale=iw*2:ih*2:flags=neighbor"
$FF $REFOPTS -framerate 25 -i "$S/fx/vhs_clean.yuv" $REFOPTS -framerate 25 -i "$S/fx/vhs_1000.yuv" \
    -filter_complex "[0:v]$C1[a];[1:v]$C1[b];[a][b]hstack" -frames:v 1 "$IMG/01-vhs-input-clean-vs-1000k.png"

order_strip vhs 1000 103 120:96:120:0 "$IMG/02-vhs-1000k-orders.png"
# The film crop is a near-black coat: luma x4 (same for every panel) so the blocks show.
order_strip film 1000 187 120:96:400:330 "$IMG/03-film-1000k-orders.png" "lutyuv=y='min(val*4\\,255)'"

# 04: |output - reference| x8, after vs per field, VHS frame 91 (field's best frame)
E="select=eq(n\,91),format=yuv420p"
$FF -i "$S/out/vhs_1000_after_qed_d1.y4m" -i "$S/out/vhs_1000_field_qed_d1.y4m" \
    $REFOPTS -framerate 50 -i "$S/fx/vhs_ref.yuv" \
    -filter_complex "[2:v]$E,split[r1][r2];[0:v]$E[a];[1:v]$E[f];\
[a][r1]blend=all_mode=difference,extractplanes=y,lut=y='min(val*8\,255)'[ea];\
[f][r2]blend=all_mode=difference,extractplanes=y,lut=y='min(val*8\,255)'[ef];[ea][ef]hstack" \
    -frames:v 1 "$IMG/04-vhs-frame91-error-x8.png"

# 05: deinterlacing off, woven frame: no deblock | woven | per field (crop of moving area)
C5="select=eq(n\,45),crop=160:96:280:200,scale=iw*3:ih*3:flags=neighbor"
$FF $REFOPTS -framerate 25 -i "$S/fx/vhs_clean.yuv" -i "$S/out/vhs_1000_none_qed_d0.y4m" \
    -i "$S/out/vhs_1000_woven_qed_d0.y4m" -i "$S/out/vhs_1000_field_qed_d0.y4m" \
    -filter_complex "[0:v]$C5[a];[1:v]$C5[b];[2:v]$C5[c];[3:v]$C5[d];[a][b][c][d]hstack=4" \
    -frames:v 1 "$IMG/05-vhs-interlaced-out-orders.png"


# 06: DCTFilter, deinterlacing off: |woven - clean| x8 | |per field - clean| x8,
# frame 45, whole frame. Needs dct.sh's outputs.
if [ -f "$S/out/vhs_1000_field_dct_d0.y4m" ]; then
  E6="select=eq(n\,45),format=yuv420p"
  $FF -i "$S/out/vhs_1000_woven_dct_d0.y4m" -i "$S/out/vhs_1000_field_dct_d0.y4m" \
      $REFOPTS -framerate 25 -i "$S/fx/vhs_clean.yuv" \
      -filter_complex "[2:v]$E6,split[r1][r2];[0:v]$E6[w];[1:v]$E6[f];\
[w][r1]blend=all_mode=difference,extractplanes=y,lut=y='min(val*8\,255)'[ew];\
[f][r2]blend=all_mode=difference,extractplanes=y,lut=y='min(val*8\,255)'[ef];[ew][ef]hstack" \
      -frames:v 1 "$IMG/06-vhs-dctfilter-error-x8.png"
fi
ls -la "$IMG"
