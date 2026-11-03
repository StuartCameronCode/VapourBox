#!/bin/bash
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/../../../.."
S="${SCRATCH:?set SCRATCH to your scratch directory}"; R=$S/report
FF="deps/macos-arm64/ffmpeg/ffmpeg -v error -y"
REF="-f rawvideo -pix_fmt yuv422p -s 320x240 -framerate 50 -i $S/gt/ref1400.yuv"
H=$S/gt/out_havSlower_1400.y4m; J=$S/gt/out_jetDefault_1400.y4m; N=$S/gt/out_jetNN1_1400.y4m
$FF -f rawvideo -pix_fmt yuv422p -s 320x240 -i $S/gt/int1400.yuv -vf "select=eq(n\,69),scale=640:480:flags=neighbor" -frames:v 1 $R/img/02-interlaced-input.png
F='select=eq(n\,138),scale=640:480:flags=neighbor'
$FF $REF -i $H -i $J -filter_complex "[0:v]${F}[a];[1:v]${F}[b];[2:v]${F}[c];[a][b][c]hstack=3" -frames:v 1 $R/img/03-frame138-full.png
C='select=eq(n\,138),crop=120:100:100:20,scale=480:400:flags=neighbor'
$FF $REF -i $H -i $J -filter_complex "[0:v]${C}[a];[1:v]${C}[b];[2:v]${C}[c];[a][b][c]hstack=3" -frames:v 1 $R/img/04-frame138-crop4x.png
E='select=eq(n\,138),format=yuv422p'
$FF $REF -i $H -i $J -filter_complex "[0:v]${E},split[r1][r2];[1:v]${E}[h];[2:v]${E}[j];[h][r1]blend=all_mode=difference,extractplanes=y,lut=y='min(val*8\,255)',scale=640:480:flags=neighbor[eh];[j][r2]blend=all_mode=difference,extractplanes=y,lut=y='min(val*8\,255)',scale=640:480:flags=neighbor[ej];[eh][ej]hstack=2" -frames:v 1 $R/img/05-frame138-error-x8.png
B='select=eq(n\,138),crop=320:20:0:220,scale=1280:80:flags=neighbor'
$FF $REF -i $H -i $J -filter_complex "[0:v]${B}[a];[1:v]${B}[b];[2:v]${B}[c];[a][b][c]vstack=3" -frames:v 1 $R/img/06-bottom-edge-4x.png
$FF $REF -i $J -i $N -filter_complex "[0:v]${C}[a];[1:v]${C}[b];[2:v]${C}[c];[a][b][c]hstack=3" -frames:v 1 $R/img/07-default-vs-tuned-crop4x.png
# Real PAL interlaced fixture: input frame 30 (woven) and outputs frame 60, crop 360x288 at 2x
$FF -i Tests/TestResources/interlaced_test.avi -vf "select=eq(n\,30),crop=360:288:180:144,scale=720:576:flags=neighbor" -frames:v 1 $R/img/08-pal-input-woven.png
P='select=eq(n\,60),crop=360:288:180:144,scale=720:576:flags=neighbor'
$FF -i $S/out_hav_Slower.y4m -i $S/out_jet_def.y4m -i $S/out_jet_nn1.y4m -filter_complex "[0:v]${P}[a];[1:v]${P}[b];[2:v]${P}[c];[a][b][c]hstack=3" -frames:v 1 $R/img/09-pal-outputs.png
