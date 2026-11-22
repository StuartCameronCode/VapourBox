#!/bin/bash
# Preview and FFV1 encode of off-grid fixtures through the worker, and whether
# the encode is the source sample for sample (tables "What happened" and
# "After the fix"). WORKER: the worker binary (default: the repo's debug build).
source "$(dirname "$0")/common.sh"
WORKER="${WORKER:-$REPO/worker/target/debug/vapourbox-worker}"
for c in "64 33 yuv420p" "63 32 yuv420p" "63 32 yuv422p" "63 33 yuv420p10le" "63 32 yuv411p" \
         "63 33 gray" "1279 719 yuv420p" "64 32 yuv420p" "63 33 yuv444p"; do
  set -- $c; w=$1 h=$2 f=$3; src="$WORK/src_${w}x${h}_$f.mkv"; out="$WORK/out_${w}x${h}_$f.mkv"
  fixture "$w" "$h" "$f" "$src"
  cat > "$WORK/job.json" <<J
{"id":"$(python3 -c 'import uuid; print(uuid.uuid4())')","inputPath":"$src","outputPath":"$out","qtgmcParameters":{"enabled":false},"processingPipeline":{"deinterlace":{"enabled":false}},"encodingSettings":{"codec":"ffv1","container":"mkv"}}
J
  "$WORKER" --config "$WORK/job.json" --preview --frame 3 > "$WORK/p.png" 2> "$WORK/p.err"; pe=$?
  "$WORKER" --config "$WORK/job.json" > "$WORK/e.out" 2>&1; ee=$?
  verdict="-"
  if [ $ee = 0 ]; then
    a=$("$FF" -v error -i "$src" -f framemd5 -pix_fmt "$f" - | grep -v '^#' | awk -F, '{print $NF}' | shasum)
    b=$("$FF" -v error -i "$out" -f framemd5 -pix_fmt "$f" - | grep -v '^#' | awk -F, '{print $NF}' | shasum)
    [ "$a" = "$b" ] && verdict="bit-exact" || verdict="differs"
  fi
  err=$(grep -o 'BlankClip: invalid [a-z]*' "$WORK/p.err" | head -1)
  echo "${w}x$h $f: preview exit $pe ${err} | encode exit $ee $(size "$out" 2>/dev/null) | $verdict"
done
