#!/bin/bash
# Generate the multi-title DVD fixture (task #27).
#
# Why it exists: the DVD import used to copy the whole title set (every title
# of the VTS, every angle, chapters ignored) instead of the title asked for.
# dvd_extract_integration_test extracts each title and chapter range from this
# folder through the worker (and libdvdread) and checks its pictures.
#
# Content: one title set (VTS 1), three titles, PAL 352x288 MPEG-2 at 25 fps,
# 12-frame GOPs, MP2 audio. Each chapter is its own <vob>, so every chapter
# boundary is exact and each chapter is a separate VOB ID (the clock restarts
# at each, as on a title that spans VOB IDs):
#
#   title 1  1 chapter                    50 frames  red
#   title 2  3 chapters  25 / 50 / 25    100 frames  grey Y~60 / Y~120 / Y~180
#   title 3  1 chapter                    75 frames  blue
#
# dvdauthor cannot author multi-angle (interleaved) titles, so the angle path
# is covered by dvd_reader.rs's synthetic unit tests only.
#
# Needs dvdauthor (brew install dvdauthor / apt install dvdauthor).
# Usage: ./generate_dvd_titles_test.sh [output_dir] [ffmpeg]
#        writes <output_dir>/dvd_titles/VIDEO_TS

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-$SCRIPT_DIR}"
FFMPEG="${2:-ffmpeg}"
DEST="$OUTPUT_DIR/dvd_titles"

command -v dvdauthor >/dev/null || { echo "dvdauthor not found" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# chapter <name> <colour> <frames>
chapter() {
    local name="$1" colour="$2" frames="$3"
    local secs
    secs="$(awk "BEGIN { printf \"%.2f\", $frames / 25 }")"
    "$FFMPEG" -v error -y \
        -f lavfi -i "color=c=$colour:s=352x288:r=25" \
        -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=$secs" \
        -frames:v "$frames" -t "$secs" \
        -c:v mpeg2video -pix_fmt yuv420p -g 12 -bf 2 -b:v 1500k -maxrate 3000k -bufsize 1835k \
        -aspect 4:3 -c:a mp2 -b:a 128k -ar 48000 \
        -f dvd "$WORK/$name.mpg"
}

chapter t1   0xFF0000 50
chapter t2c1 0x3C3C3C 25
chapter t2c2 0x787878 50
chapter t2c3 0xB4B4B4 25
chapter t3   0x0000FF 75

cat > "$WORK/dvd.xml" <<XML
<dvdauthor dest="$WORK/out">
  <vmgm />
  <titleset>
    <titles>
      <video format="pal" aspect="4:3" resolution="352x288" />
      <pgc><vob file="$WORK/t1.mpg" chapters="0" /></pgc>
      <pgc>
        <vob file="$WORK/t2c1.mpg" chapters="0" />
        <vob file="$WORK/t2c2.mpg" chapters="0" />
        <vob file="$WORK/t2c3.mpg" chapters="0" />
      </pgc>
      <pgc><vob file="$WORK/t3.mpg" chapters="0" /></pgc>
    </titles>
  </titleset>
</dvdauthor>
XML

VIDEO_FORMAT=PAL dvdauthor -x "$WORK/dvd.xml" >"$WORK/dvdauthor.log" 2>&1 || {
    cat "$WORK/dvdauthor.log" >&2
    exit 1
}

rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$WORK/out/VIDEO_TS" "$DEST/"
# dvdauthor also writes an empty AUDIO_TS on some versions; not needed.

# The VMG must list three titles (TT_SRPT at the sector named at 0xC4).
titles="$(python3 -I - "$DEST/VIDEO_TS/VIDEO_TS.IFO" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
sector = int.from_bytes(d[0xC4:0xC8], 'big')
print(int.from_bytes(d[sector * 2048:sector * 2048 + 2], 'big'))
PY
)"
if [ "$titles" != 3 ]; then
    echo "expected 3 titles in VIDEO_TS.IFO, got $titles" >&2
    exit 1
fi
echo "Wrote $DEST/VIDEO_TS ($(du -sh "$DEST" | cut -f1))"
