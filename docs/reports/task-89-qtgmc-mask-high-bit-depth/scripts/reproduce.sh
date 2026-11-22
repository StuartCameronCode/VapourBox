#!/bin/sh
# Re-runs every number in the task #89 report against a deps bundle.
#   docs/reports/task-89-qtgmc-mask-high-bit-depth/scripts/reproduce.sh <deps/<platform>>
# Writes ../data/*_<platform>.txt. macOS/Linux bundles (R78 Python package).
set -eu
DEPS=$(cd "$1" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
PLAT=$(basename "$DEPS")
CFG=$(mktemp -d)
export PYTHONHOME="$DEPS/python" PYTHONPATH="$DEPS/python-packages:$DEPS" XDG_CONFIG_HOME="$CFG"
export DYLD_LIBRARY_PATH="$DEPS/lib" LD_LIBRARY_PATH="$DEPS/lib"
export VAPOURBOX_FFMPEG="$DEPS/ffmpeg/ffmpeg"
[ -x "$VAPOURBOX_FFMPEG" ] || VAPOURBOX_FFMPEG="$DEPS/bin/ffmpeg"
PY="$DEPS/python/bin/python3"
mkdir -p "$HERE/../data"
VER=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$DEPS/version.json")
for s in stand_in factor_sweep; do
    { echo "# $s.py, deps $VER, $PLAT"; "$PY" "$HERE/$s.py"; } > "$HERE/../data/${s}_${PLAT}_$VER.txt"
done
"$PY" "$HERE/../../task-79-qtgmc-mask-avx2/scripts/mask_depths.py" > "$HERE/../data/mask_depths_${PLAT}_$VER.txt"
rm -rf "$CFG"
