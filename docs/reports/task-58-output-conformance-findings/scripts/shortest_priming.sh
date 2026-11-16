#!/usr/bin/env bash
# Finding 1: a 50-picture trim into AVI whose sound (a WAV exactly the
# window long, as Audio Restoration renders it) is read late by AAC's
# priming. -shortest drops the last picture; -t the window keeps it.
set -euo pipefail
source "$(dirname "$0")/common.sh"
cd "$SCRATCH"
"$FFMPEG" -v error -y -f lavfi -i testsrc2=size=160x120:rate=25 -frames:v 50 -pix_fmt yuv420p v50.y4m
"$FFMPEG" -v error -y -f lavfi -i sine=f=200:sample_rate=48000 -t 2.0 -c:a pcm_f32le w.wav
"$FFMPEG" -v error -y -f lavfi -i sine=f=200:sample_rate=48000 -t 2.021333 -c:a pcm_f32le wp.wav
P=0.021334  # 1024 / 48000, rounded up
row() {
  local name="$1"; shift
  "$FFMPEG" -v error -y -f yuv4mpegpipe -i v50.y4m "$@" -c:v ffv1 -c:a aac out.avi
  printf '%-45s pictures %s, audio %s s\n' "$name" \
    "$("$FFPROBE" -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 out.avi)" \
    "$("$FFPROBE" -v error -select_streams a:0 -show_entries stream=duration -of csv=p=0 out.avi)"
}
row "-ss P on the exact WAV, -shortest (before)" -ss $P -i w.wav -map 0:v -map 1:a -avoid_negative_ts disabled -shortest
row "no priming seek, -shortest" -i w.wav -map 0:v -map 1:a -shortest
row "WAV P longer, -shortest" -ss $P -i wp.wav -map 0:v -map 1:a -avoid_negative_ts disabled -shortest
row "no -shortest" -ss $P -i w.wav -map 0:v -map 1:a -avoid_negative_ts disabled
row "-t 2 instead of -shortest (after)" -ss $P -i w.wav -map 0:v -map 1:a -avoid_negative_ts disabled -t 2
