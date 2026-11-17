#!/bin/bash
# Reproduces every number in ../index.html.
#
#   SCRATCH=/some/scratch/dir [DEPS=deps/macos-arm64] [BASE=<git rev>] ./reproduce.sh
#
# BASE is the commit before task #57's template change (default: the merge
# base with main at the time of writing); its templates are the "before".
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
S="${SCRATCH:?set SCRATCH to your scratch directory}"
D="$(cd "${DEPS:-$REPO/deps/macos-arm64}" && pwd)"
BASE="${BASE:-93ce194}"
mkdir -p "$S/old"
git -C "$REPO" archive "$BASE" worker/templates | tar -x -C "$S/old"
py() {
  PYTHONHOME="$D/python" PYTHONPATH="$D:$D/python-packages" PYTHONNOUSERSITE=1 \
    XDG_CONFIG_HOME="$D/config" VAPOURBOX_PLATFORM="$(basename "$D")" VAPOURBOX_FFMPEG="$D/ffmpeg/ffmpeg" SCRATCH="$S" \
    OLD_TEMPLATES="$S/old/worker/templates" "$D/python/bin/python3" "$@"
}
cd "$HERE"
py heights.py > "$S/heights.json"
py module_identity.py | tail -1 > "$S/module_identity.json"
py padding_effect.py | tail -1 > "$S/padding_effect.json"
py removedirt.py repeat | tail -1 > "$S/removedirt_repeat.json"
py removedirt.py order > "$S/removedirt_order.json"
py removedirt.py speed | tail -1 > "$S/removedirt_speed.json"
for n in 1000 6000; do
  for m in bare wrapped; do py removedirt.py rss $m $n | tail -1; done
done > "$S/removedirt_rss.json"
for m in loop loopcrop fe fecrop; do py removedirt_leak.py $m | tail -1; done > "$S/removedirt_leak.json"
# The table: re-measure the calls task #57 touches.
py "$REPO/Scripts/probe-plugin-formats.py" --jobs 6 --ffmpeg "$D/ffmpeg/ffmpeg" \
  --calls dctf.DCTFilter,deblock.Deblock,havsfunc.Deblock_QED,havsfunc.FixChromaBleedingMod,havsfunc.LSFmod,sangnom.SangNom,temporaldegrain2.TemporalDegrain2,havsfunc.QTGMC,havsfunc.MCTemporalDenoise,srestore.unblend,stabilize.weave,bifrost.Bifrost,dedot.Dedot,descratch.DeScratch,havsfunc.LUTDeCrawl,havsfunc.LUTDeRainbow,removedirt.remove_dirt \
  --out "$REPO/Tests/TestResources/plugin_format_table.json"
