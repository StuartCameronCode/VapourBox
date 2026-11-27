#!/bin/bash
# Converts crops.py's PGMs into the report's img/*.png, scaled 2x
# nearest-neighbour so the pixels are real.
#   SCRATCH=<dir> make_images.sh <deps dir>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${SCRATCH:?set SCRATCH to a scratch directory}"
FFMPEG="$(cd "$1" && pwd)/ffmpeg/ffmpeg"
for f in "$SCRATCH"/img/*.pgm; do
    "$FFMPEG" -v error -y -i "$f" -vf scale=iw*2:ih*2:flags=neighbor "$HERE/../img/$(basename "${f%.pgm}").png"
done
ls -l "$HERE/../img"
