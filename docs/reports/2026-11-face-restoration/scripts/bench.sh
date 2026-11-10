#!/bin/bash
# Every run behind the report's speed and flicker tables, in order.
#
#   DEPS, ADDONS, VAPOURBOX_ADDON_STAGING   as for run.sh
#   WORK=<scratch dir>                      outputs (.npy, .png, results.jsonl)
#   CLEAN=<face_clean.mkv>  HD=<face_1080.mp4>   built by make_refs.sh
#
# The fixture is the committed Tests/TestResources/face_restore_test.mp4.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
: "${WORK:?set WORK to a scratch directory}" "${CLEAN:?}" "${HD:?}"
FIX="$REPO/Tests/TestResources/face_restore_test.mp4"
OUT="$WORK/runs"
mkdir -p "$OUT"
R() { "$HERE/run.sh" face_run.py "$@" | tee -a "$WORK/results.jsonl"; }

# Flicker: smoothing off / landmarks only / landmarks + blend, radius 1 and 2.
R --clip "$FIX" --radius 0 --save-y --out "$OUT" --tag rf_r0 --png 30 --png 75
R --clip "$FIX" --radius 1 --no-blend --save-y --out "$OUT" --tag rf_r1_landmarks --png 30
R --clip "$FIX" --radius 1 --save-y --out "$OUT" --tag rf_r1 --png 30 --png 75
R --clip "$FIX" --radius 2 --save-y --out "$OUT" --tag rf_r2 --png 30
R --clip "$FIX" --radius 1 --strength 0.8 --save-y --out "$OUT" --tag rf_r1_s08 --png 75
R --clip "$FIX" --radius 1 --strength 0 --save-y --out "$OUT" --tag input
R --clip "$FIX" --radius 1 --det mnet --save-y --out "$OUT" --tag rf_r1_mnet
for m in gfpgan codeformer; do
  R --clip "$FIX" --model $m --radius 0 --save-y --out "$OUT" --tag ${m}_r0 --png 75
  R --clip "$FIX" --model $m --radius 1 --save-y --out "$OUT" --tag ${m}_r1 --png 75
done
"$HERE/run.sh" luma_npy.py "$CLEAN" "$WORK/clean_y.npy" 2>/dev/null || true

# Speed: SD (the fixture) and 1080p, Core ML (default) vs the CPU.
R --clip "$FIX" --frames 0:60 --tag speed_sd_coreml
R --clip "$HD" --frames 0:60 --tag speed_hd_coreml
VAPOURBOX_AI_FORCE_CPU=1 R --clip "$FIX" --frames 0:12 --tag speed_sd_cpu
VAPOURBOX_AI_FORCE_CPU=1 R --clip "$HD" --frames 0:12 --tag speed_hd_cpu
for m in gfpgan codeformer; do
  R --clip "$FIX" --model $m --frames 0:60 --tag speed_sd_coreml_$m
done
