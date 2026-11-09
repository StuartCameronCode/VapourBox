#!/bin/bash
# Fetch the outside footage the fixtures are made from into $SCRATCH/src.
# Only building the fixtures needs the network; nothing in the report does.
#
# * Kodak PhotoCD images (Kodak released them for unrestricted use), from the
#   usual mirror.
# * "NASA Astronaut Anne McClain Talks with Fox13 News, Seattle - March 31,
#   2025" (NASA JSC, public domain as a work of NASA), 1080p, Wikimedia
#   Commons: the first 80 MB.
# * "Night of the Living Dead" (1968; public domain), 1440x1080 10-bit AV1,
#   Wikimedia Commons: the first 90 MB.
set -e
S="${SCRATCH:?set SCRATCH to your scratch directory}/src"
mkdir -p "$S"
cd "$S"
UA="VapourBox-test-fixtures/1.0 (https://github.com/StuartCameronCode/VapourBox)"
[ -f nasa.webm ] || curl -fsS --retry 5 --retry-all-errors -A "$UA" -r 0-80000000 -o nasa.webm \
  "https://upload.wikimedia.org/wikipedia/commons/f/f0/NASA_Astronaut_Anne_McClain_Talks_with_Fox13_News%2C_Seattle_%E2%80%93_March_31%2C_2025_%28iss072m260901634%29.webm"
[ -f notld.webm ] || curl -fsS --retry 5 --retry-all-errors -A "$UA" -r 0-90000000 -o notld.webm \
  "https://upload.wikimedia.org/wikipedia/commons/2/24/Night_of_the_Living_Dead_%281968%29.webm"
for k in 01 03 05 08 13 19 23; do
  [ -f kodim$k.png ] || curl -fsSL -o kodim$k.png "https://r0k.us/graphics/kodak/kodak/kodim$k.png"
done
ls -la
