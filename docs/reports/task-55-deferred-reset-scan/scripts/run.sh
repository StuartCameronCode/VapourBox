#!/bin/bash
# Reproduce every number in the report (task #55: the timestamp-reset scan
# deferred out of analysis).
#
# Needs two debug workers: BEFORE built from the commit this task started
# from (dc9e36c) and AFTER from this branch, e.g.
#   git worktree add "$WORK/base" dc9e36c && (cd "$WORK/base/worker" && cargo build)
# and the deps bundle for ffmpeg ($VAPOURBOX_DEPS_DIR, default the app's
# install under ~/Library/Application Support/VapourBox/deps/macos-arm64).
#
#   T55_WORK    scratch directory (default: a temporary one): the synthetic
#               sources are written here (1 GB and 2 GB)
#   T55_BEFORE  the BEFORE worker binary
#   T55_AFTER   the AFTER worker binary
#   T55_VOBS    four ~1 GB VOB parts of one title on a network share,
#               space-separated (one cold read per part per measure, rotated);
#               the share step is skipped without them
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${T55_WORK:-$(mktemp -d)}"
mkdir -p "$WORK"
FFMPEG="${VAPOURBOX_DEPS_DIR:-$HOME/Library/Application Support/VapourBox/deps/macos-arm64}/ffmpeg/ffmpeg"
cd "$HERE"

# A 16-minute PAL DVD-style program stream (MPEG-2 8 Mbit/s, GOP 12, AC-3),
# about 1 GB, and the same file twice over: its clock goes back at the join.
SRC="$WORK/pal_16min.vob"
if [ ! -f "$SRC" ]; then
  "$FFMPEG" -v error -f lavfi -i "testsrc2=size=720x576:rate=25,noise=alls=12:allf=t" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 960 \
    -c:v mpeg2video -b:v 8000k -maxrate 9000k -bufsize 1835k -g 12 -bf 2 \
    -c:a ac3 -b:a 192k -f vob -y "$SRC"
fi
[ -f "$WORK/pal_reset.vob" ] || cat "$SRC" "$SRC" > "$WORK/pal_reset.vob"

python3 -I analysis_probe.py local "$T55_BEFORE" "$T55_AFTER" ../data/local.json "$SRC" 3
python3 -I analysis_probe.py reset "$T55_BEFORE" "$T55_AFTER" ../data/reset_local.json "$WORK/pal_reset.vob"
if [ -n "${T55_VOBS:-}" ]; then
  # shellcheck disable=SC2086
  python3 -I analysis_probe.py share "$T55_BEFORE" "$T55_AFTER" ../data/share.json $T55_VOBS
fi
echo "Results in $HERE/../data"
