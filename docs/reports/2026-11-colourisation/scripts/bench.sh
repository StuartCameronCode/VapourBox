#!/bin/bash
# Every run behind the report's flicker and speed tables, in order. Run on an
# otherwise idle machine: the speed numbers are wall-clock.
#
#   DEPS, ADDONS, VAPOURBOX_ADDON_STAGING   as for run.sh
#   WORK=<scratch dir>                      outputs (.npy, .png, results.jsonl)
#   HD=<colorize_hd.mp4>                    built by make_refs.sh
#
# The SD fixture is the committed Tests/TestResources/colorize_test.mp4.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
: "${WORK:?set WORK to a scratch directory}" "${HD:?}"
FIX="$REPO/Tests/TestResources/colorize_test.mp4"
OUT="$WORK/runs"
mkdir -p "$OUT"
R() { timeout 1800 "$HERE/run.sh" colorize_run.py "$@" 2>/dev/null | grep '^{' | tee -a "$WORK/results.jsonl"; }

# Flicker: each model per frame (radius 0) and smoothed over 1, 2 and 3 frames
# either side; and radius 2 with the motion weighting off (every neighbour
# blended in full), to show what the weighting is for.
for m in ddcolor deoldify; do
  R --clip "$FIX" --model $m --radius 0 --save-uv --out "$OUT" --tag ${m}_r0 --png 20 --png 110
  R --clip "$FIX" --model $m --radius 1 --save-uv --out "$OUT" --tag ${m}_r1
  R --clip "$FIX" --model $m --radius 2 --save-uv --out "$OUT" --tag ${m}_r2 --png 20 --png 110
  R --clip "$FIX" --model $m --radius 3 --save-uv --out "$OUT" --tag ${m}_r3
  R --clip "$FIX" --model $m --radius 2 --motion-limit 1e9 --save-uv --out "$OUT" --tag ${m}_r2nomotion
done
# Strength, for the figure (frame 110, its smoothing neighbours included).
R --clip "$FIX" --model ddcolor --strength 0.5 --frames 108:113 --out "$OUT" --tag ddcolor_s05 --png 2
R --clip "$FIX" --model ddcolor --strength 1.5 --frames 108:113 --out "$OUT" --tag ddcolor_s15 --png 2

# Speed: SD (the fixture) and 1080p, the preferred provider (Core ML) vs the
# CPU, at each model's default size and radius 2. setupSeconds is session
# creation, which includes Core ML's compilation.
R --clip "$FIX" --model ddcolor --tag speed_sd_ddcolor_coreml
R --clip "$FIX" --model deoldify --tag speed_sd_deoldify_coreml
R --clip "$HD" --model ddcolor --tag speed_hd_ddcolor_coreml
R --clip "$HD" --model deoldify --tag speed_hd_deoldify_coreml
VAPOURBOX_AI_FORCE_CPU=1 R --clip "$FIX" --model ddcolor --frames 0:24 --tag speed_sd_ddcolor_cpu
VAPOURBOX_AI_FORCE_CPU=1 R --clip "$FIX" --model deoldify --frames 0:24 --tag speed_sd_deoldify_cpu
VAPOURBOX_AI_FORCE_CPU=1 R --clip "$HD" --model ddcolor --frames 0:12 --tag speed_hd_ddcolor_cpu
VAPOURBOX_AI_FORCE_CPU=1 R --clip "$HD" --model deoldify --frames 0:12 --tag speed_hd_deoldify_cpu
# A preview's process: DDColor on the CPU (preview=True), five frames.
R --clip "$FIX" --model ddcolor --preview --frames 50:55 --tag speed_preview_ddcolor
R --clip "$FIX" --model deoldify --preview --frames 50:55 --tag speed_preview_deoldify

# Already-colour input: the face fixture (colour), recoloured by each model.
R --clip "$REPO/Tests/TestResources/face_restore_test.mp4" --model ddcolor --frames 60:61 --out "$OUT" --tag colour_ddcolor --png 0
R --clip "$REPO/Tests/TestResources/face_restore_test.mp4" --model deoldify --frames 60:61 --out "$OUT" --tag colour_deoldify --png 0
