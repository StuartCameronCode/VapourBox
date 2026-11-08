#!/bin/bash
# Generate face_restore_test.mp4: a 5-second, VHS-like SD clip with a real face,
# for the Face Restoration pass's tests (integration_face_restore_test.dart).
#
# Provenance: "NASA Astronaut Anne McClain Talks with Fox13 News, Seattle –
# March 31, 2025" (NASA Johnson Space Center, catalogue iss072m260901634),
# from Wikimedia Commons, where it is marked public domain as a work of NASA, a
# US government agency:
#   https://commons.wikimedia.org/wiki/File:NASA_Astronaut_Anne_McClain_Talks_with_Fox13_News,_Seattle_%E2%80%93_March_31,_2025_(iss072m260901634).webm
# NASA's media guidelines ask that NASA material not be used to imply
# endorsement; a test fixture does not.
#
# The clip is seconds 50-55 of the 1080p original, cropped to the astronaut's
# upper body (so the face is ~90 px tall at SD, a size face restoration is
# meant for), scaled to 640x480 at 29.97 fps, then degraded the way a VHS dub
# is: luma resolution cut to 256x360, chroma to a quarter of the width,
# temporal noise, and a soft H.264 encode.
#
# Usage: ./generate_face_test.sh <source.webm> [ffmpeg]
# (the first ~80 MB of the original is enough: `curl -r 0-80000000 -o src.webm <url>`)
set -euo pipefail
SRC="${1:?usage: $0 <source.webm> [ffmpeg]}"
FFMPEG="${2:-ffmpeg}"
OUT="$(cd "$(dirname "$0")" && pwd)/face_restore_test.mp4"

"$FFMPEG" -y -v error -ss 50 -t 5 -i "$SRC" -an \
  -vf "fps=30000/1001,crop=720:540:728:140,scale=640:480:flags=lanczos,\
scale=256:360:flags=area,scale=640:480:flags=bicubic,format=yuv420p,\
split[y][c];[c]scale=160:480:flags=bicubic,scale=640:480:flags=bicubic[cb];\
[y][cb]mergeplanes=0x001112:yuv420p,noise=alls=8:allf=t,setsar=1" \
  -c:v libx264 -preset slow -crf 27 -pix_fmt yuv420p \
  -color_primaries bt470bg -color_trc bt709 -colorspace smpte170m -color_range tv \
  -movflags +faststart "$OUT"
ls -l "$OUT"
