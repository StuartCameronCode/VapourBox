#!/bin/bash
# Reproduces every number in ../index.html (task #92).
#
#   SCRATCH=/some/scratch/dir ./reproduce.sh
#
# Needs the macOS arm64 deps bundle the app pins (deps/macos-arm64, unzipped
# from the release deps-version.json names); only its ffmpeg is used.
# Writes ../data/*.txt. The fixtures (lossless FFV1, ~60 MB) stay in SCRATCH.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
S="${SCRATCH:?set SCRATCH to your scratch directory}"
F="${FFMPEG:-$REPO/deps/macos-arm64/ffmpeg/ffmpeg}"
DATA="$HERE/../data"
mkdir -p "$S" "$DATA"
"$F" -version | head -1 > "$DATA/ffmpeg_version.txt"
"$HERE/make_fixtures.sh" "$F" "$REPO/Tests/TestResources" "$S"
( cd "$S" && "$HERE/refusals.sh" "$F" vhs422.mkv vhs420.mkv ) > "$DATA/refusals.txt"
( cd "$S" && for src in vhs420.mkv dvb420.mkv; do for br in 1000k 2500k 5000k; do
    echo "== $src $br"; "$HERE/quality.sh" "$F" "$src" "$br"; done; done ) > "$DATA/quality.txt"
( cd "$S" && "$HERE/other_codecs.sh" "$F" vhs420.mkv ) > "$DATA/other_codecs.txt"
