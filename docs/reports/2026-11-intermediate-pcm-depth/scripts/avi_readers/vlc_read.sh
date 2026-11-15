#!/bin/sh
# VLC's read of the AVI fixtures (F6 of ../../index.html), on any platform:
# transcodes each fixture's audio to 32-bit PCM WAV, which compare.py checks
# against the stored samples.
#
#   WORK=/scratch VLC=/Applications/VLC.app/Contents/MacOS/VLC ./vlc_read.sh
set -e
: "${WORK:?}" "${VLC:=vlc}"
mkdir -p "$WORK/local"
for fx in ffv1_s24 huffyuv_s24 h264_s24 ffv1_s16; do
  out="$WORK/local/vlc_$fx.wav"
  rm -f "$out"
  "$VLC" --version 2>/dev/null | head -1 > "$WORK/local/vlc_$fx.status"
  "$VLC" -I dummy --no-video "$WORK/avi/$fx.avi" \
    --sout "#transcode{vcodec=none,acodec=s32l}:std{access=file,mux=wav,dst=$out}" vlc://quit \
    > "$WORK/local/vlc_$fx.log" 2>&1 || true
done
