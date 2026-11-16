#!/bin/bash
# Reproduces every table in ../index.html.
#
#   SCRATCH=/some/scratch/dir [DEPS=deps/macos-arm64] [BASE=<git rev>] ./reproduce.sh
#
# 1. The full probe against the bundle -> Tests/TestResources/plugin_format_table.json
#    (about an hour on an M1 Pro with 6 jobs; the 1080p cells of the denoisers dominate).
# 2. The identity check: every migrated pass encoded losslessly with the
#    templates at BASE (default: the commit before task #48's template change)
#    and with the working tree's, frame MD5s compared.
# 3. The tables in ../index.html, from both.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
S="${SCRATCH:?set SCRATCH to your scratch directory}"
D="$(cd "${DEPS:-$REPO/deps/macos-arm64}" && pwd)"
BASE="${BASE:-97d6a45}"
mkdir -p "$S"
py() {
  PYTHONHOME="$D/python" PYTHONPATH="$D:$D/python-packages" PYTHONNOUSERSITE=1 \
    XDG_CONFIG_HOME="$D/config" VAPOURBOX_PLATFORM="$(basename "$D")" "$D/python/bin/python3" "$@"
}

py "$REPO/Scripts/probe-plugin-formats.py" --jobs 6 --ffmpeg "$D/ffmpeg/ffmpeg" \
  --out "$REPO/Tests/TestResources/plugin_format_table.json"

rm -rf "$S/base" && mkdir -p "$S/base"
git -C "$REPO" archive "$BASE" worker/templates | tar -x -C "$S/base"
(cd "$REPO/worker" && cargo build)
python3 "$HERE/identity.py" --worker "$REPO/worker/target/debug/vapourbox-worker" \
  --old "$S/base/worker/templates" --new "$REPO/worker/templates" \
  --ffmpeg "$D/ffmpeg/ffmpeg" --work "$REPO/worker/target/identity" | tee "$S/identity.txt" || true

python3 "$HERE/render_table.py" "$S/identity.txt"

# 4. RemoveDirt's run-to-run differences (section 4), on a job identity.py wrote.
python3 "$HERE/repeat.py" --work "$REPO/worker/target/identity" --ffmpeg "$D/ffmpeg/ffmpeg" \
  --job removedirt_yuv420p_progressive --runs 10
