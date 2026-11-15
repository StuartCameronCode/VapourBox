#!/bin/bash
# ffmpeg and VLC: how each times an AVI with AAC packets over nBlockAlign,
# before and after the header fix. VLC's own timestamps are read by remuxing
# through VLC (--sout to MKV), then probing that file.
#
#   ./readers_local.sh <ffmpeg dir> <VLC binary> <work dir>
#
# Needs the fixtures of windows/make_fixtures.py in <work dir> (run with
# FFMPEG=<ffmpeg dir>/ffmpeg first).
set -euo pipefail
FF="$1"; VLC="$2"; W="$3"
here="$(cd "$(dirname "$0")" && pwd)"
for f in mono256 mono256_patched mono192 mono192_patched stereo192; do
    avi="$W/$f.avi"
    ff=$("$FF/ffprobe" -v error -select_streams a:0 -show_entries packet=pts -of csv=p=0 "$avi" |
        awk 'NR>1 && $1!=p+1{g++} {p=$1; n++} END{printf "packets %d, gaps %d, last pts %d", n, g, p}')
    rm -f "$W/vlc_$f.mkv"
    "$VLC" -I dummy --play-and-exit "$avi" --sout "#std{access=file,mux=mkv,dst=$W/vlc_$f.mkv}" vlc://quit >/dev/null 2>&1 || true
    vlc=$("$FF/ffprobe" -v error -select_streams a:0 -show_entries packet=pts_time -of csv=p=0 "$W/vlc_$f.mkv" |
        awk 'NR>1{d=$1-p; if(d>0.0223)c++} {p=$1;n++} END{printf "packets %d, late steps %d, last %.3f s", n, c, p}')
    cmp -s <("$FF/ffmpeg" -v error -i "$W/${f%_patched}.avi" -f s16le -) <("$FF/ffmpeg" -v error -i "$avi" -f s16le -) \
        && same=identical || same=DIFFERENT
    echo "{\"file\": \"$f\", \"ffmpeg\": \"$ff\", \"vlc\": \"$vlc\", \"decoded_vs_unpatched\": \"$same\"}"
done
python3 -I "$here/riff_block_align.py" show "$W"/*.avi
