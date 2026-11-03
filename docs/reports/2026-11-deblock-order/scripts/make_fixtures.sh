#!/bin/bash
# Builds the fixtures for the deblock-order probe into $SCRATCH/fx.
#
#   film  - 240 frames of Tests/TestResources/small_clip.mp4 (frames 1400-1639),
#           treated as 50 Hz field-time samples, upscaled to 720x576 and woven
#           into 120 TFF interlaced frames. ref.yuv is the 50p ground truth.
#   vhs   - Tests/TestResources/interlaced_test.avi, a real 720x576 TFF capture
#           stored losslessly (Lagarith). No ground truth exists for it.
#
# Each clean interlaced clip is then encoded to MPEG-2 the way a DVD or a
# capture card would (interlaced DCT + interlaced motion estimation, TFF, 4:2:0)
# at each bitrate in $RATES, and decoded back to raw. Everything is yuv420p.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/../../../.."
S="${SCRATCH:?set SCRATCH to your scratch directory}"
FF="deps/macos-arm64/ffmpeg/ffmpeg -v error -y"
RATES="${RATES:-1000 1500 3000}"
mkdir -p "$S/fx"

# film: progressive 50p truth, then woven to 25i
$FF -i Tests/TestResources/small_clip.mp4 \
    -vf "select=between(n\,1400\,1639),setpts=N/50/TB,scale=720:576:flags=spline,format=yuv420p" \
    -fps_mode passthrough -f rawvideo "$S/fx/film_ref.yuv"
$FF -f rawvideo -pix_fmt yuv420p -s 720x576 -framerate 50 -i "$S/fx/film_ref.yuv" \
    -vf interlace=scan=tff:lowpass=0 -fps_mode passthrough -f rawvideo "$S/fx/film_clean.yuv"

# vhs: 4:2:2 -> 4:2:0 resampled per field (interl=1), as a DVD authoring tool would
$FF -i Tests/TestResources/interlaced_test.avi \
    -vf "scale=interl=1,format=yuv420p" -f rawvideo "$S/fx/vhs_clean.yuv"

for fx in film vhs; do
  for r in $RATES; do
    $FF -f rawvideo -pix_fmt yuv420p -s 720x576 -framerate 25 -i "$S/fx/${fx}_clean.yuv" \
        -vf setfield=tff -c:v mpeg2video -flags +ildct+ilme -g 12 -bf 2 \
        -b:v ${r}k -maxrate ${r}k -bufsize $((r * 2))k \
        "$S/fx/${fx}_${r}.m2v"
    $FF -i "$S/fx/${fx}_${r}.m2v" -f rawvideo -pix_fmt yuv420p "$S/fx/${fx}_${r}.yuv"
  done
done
ls -la "$S/fx"
