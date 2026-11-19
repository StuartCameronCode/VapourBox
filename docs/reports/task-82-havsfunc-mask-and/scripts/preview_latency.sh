#!/usr/bin/env bash
# Task #82: wall time of the worker's preview of a 10-bit 4:2:2 source with
# Chroma Fixes' LUTDeCrawl and LUTDeRainbow on, with the bundle's havsfunc as
# it is and with another havsfunc.py (upstream's tables) swapped in; the swap
# is undone on exit. Prints one line per run and the PNGs' md5s.
#   preview_latency.sh <worker> <deps/<platform>> <other havsfunc.py> [runs]
# The worker must find that deps dir (a debug build searches upward from
# itself). Scratch files go to $WORK (default: a new temp directory).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
WORKER="$1"; DEPS="$(cd "$2" && pwd)"; OTHER="$3"; RUNS="${4:-5}"
WORK="${WORK:-$(mktemp -d)}"
HAF="$DEPS/python-packages/havsfunc.py"
SRC="$REPO/Tests/TestResources/prores422_10bit_telecine.mov"

cat > "$WORK/job.json" <<JSON
{"id":"82828282-0000-4000-8000-000000000082","inputPath":"$SRC","outputPath":"$WORK/unused.mkv",
 "qtgmcParameters":{"enabled":false},
 "processingPipeline":{"deinterlace":{"enabled":false},
   "chromaFixes":{"enabled":true,"applyDeCrawl":true,"applyDeRainbow":true}},
 "encodingSettings":{}}
JSON

cp "$HAF" "$WORK/havsfunc.bundle.py"
trap 'cp "$WORK/havsfunc.bundle.py" "$HAF"' EXIT

run() {  # $1 label
    for i in $(seq "$RUNS"); do
        local t0 t1
        t0=$(python3 -c 'import time; print(time.time())')
        "$WORKER" --config "$WORK/job.json" --preview --frame 10 > "$WORK/$1.png" 2> "$WORK/$1.log"
        t1=$(python3 -c 'import time; print(time.time())')
        python3 -c "print('$1 run $i: %.2f s' % ($t1 - $t0))"
    done
    echo "$1 png md5: $(md5 -q "$WORK/$1.png" 2>/dev/null || md5sum "$WORK/$1.png" | cut -d' ' -f1)"
}

run bundle
cp "$OTHER" "$HAF"
run other
