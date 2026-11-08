#!/bin/bash
# Generate colorize_test.mp4: a 5-second black-and-white SD clip of real film,
# for the Colourisation pass's tests (integration_colorize_test.dart) and its
# report (docs/reports/2026-11-colourisation).
#
# Provenance: "Diary of a Sergeant" (1945), a US War Department film (Army
# Pictorial Service, MISC. 1129; National Archives 111-M-1129), from
# Wikimedia Commons, where it is marked public domain as a work of the US
# federal government:
#   https://commons.wikimedia.org/wiki/File:Diary_of_a_Sergeant_(1945).webm
# (1920x1080 VP9, the 4:3 picture pillarboxed, 24 fps).
#
# The clip is seconds 156-161: a close-up of a face, a dissolve, and a two-shot
# of two men at a bedside (skin, hair, white cotton, bedding), with the
# pillarbox cropped off, scaled to 640x480, and its chroma made exactly
# neutral (the scan carries a faint tint; a black-and-white source should
# carry none).
#
# Usage: ./generate_colorize_test.sh <source.webm> [ffmpeg]
# (the first ~80 MB of the original is enough: `curl -r 0-80000000 -o src.webm <url>`)
set -euo pipefail
SRC="${1:?usage: $0 <source.webm> [ffmpeg]}"
FFMPEG="${2:-ffmpeg}"
OUT="$(cd "$(dirname "$0")" && pwd)/colorize_test.mp4"

"$FFMPEG" -y -v error -ss 156 -t 5 -i "$SRC" -an \
  -vf "crop=1440:1080:240:0,scale=640:480:flags=lanczos,format=gray,format=yuv420p,setsar=1" \
  -c:v libx264 -preset slow -crf 20 -pix_fmt yuv420p \
  -color_primaries bt470bg -color_trc bt709 -colorspace smpte170m -color_range tv \
  -movflags +faststart "$OUT"
ls -l "$OUT"
