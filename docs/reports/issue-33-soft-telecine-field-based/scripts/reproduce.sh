#!/bin/bash
# Reproduces every number and image in ../index.html.
#
#   SCRATCH=/some/scratch/dir [DEPS=deps/macos-arm64] ./reproduce.sh
#
# Sections 1-3 and the crops come from probe.py. The encode numbers come from
# app/test/integration_soft_telecine_field_based_test.dart (heavy), which this
# script runs too; with BEFORE=1 it also runs that test against the worker
# built from the commit before the fix (7ef3a99), in a scratch worktree.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
S="${SCRATCH:?set SCRATCH to your scratch directory}"
D="$(cd "${DEPS:-$REPO/deps/macos-arm64}" && pwd)"
FF="$D/ffmpeg/ffmpeg"
R="$REPO/Tests/TestResources"
mkdir -p "$S/img"
q() { "$FF" -hide_banner -loglevel error -y "$@"; }
py() {
  PYTHONHOME="$D/python" PYTHONPATH="$D:$D/python-packages:$HERE" PYTHONNOUSERSITE=1 \
    XDG_CONFIG_HOME="$D/config" "$D/python/bin/python3" "$@"
}

# The fixture as the worker's decoder sees it (constant-rate, 150 frames).
q -i "$R/soft_telecine_dvd.mkv" -f rawvideo -pix_fmt yuv420p "$S/st.yuv"
# Ground truth 1: the top fields of a real VHS capture, each a progressive
# picture with full vertical chroma (4:2:2).
q -i "$R/interlaced_test.avi" -frames:v 24 -vf "field=top" -f rawvideo -pix_fmt yuv422p "$S/vhs.yuv"
# Ground truth 2: testsrc2 rendered at 4:2:2 (sharp colour edges).
q -f lavfi -i "testsrc2=size=720x480:rate=24:duration=1" -vf format=yuv422p -f rawvideo "$S/ts.yuv"

py "$HERE/probe.py" "$S/st.yuv" "$S/vhs.yuv" "$S/ts.yuv" "$S/img"
i=1
for n in source420 per_field progressive; do
  q -f rawvideo -pix_fmt gray -s 64x64 -i "$S/img/$n.gray" -vf scale=384:384:flags=neighbor \
    "$HERE/../img/0$i-$n.png"
  i=$((i + 1))
done

echo; echo "== Encodes (heavy test, this checkout)"
( cd "$REPO/worker" && cargo build -q 2>/dev/null )
( cd "$REPO/app" && VAPOURBOX_DEPS_DIR="$D" flutter test --tags heavy \
    test/integration_soft_telecine_field_based_test.dart 2>&1 | grep -E "MAD|passed|failed|Expected|Actual" )

if [ "${BEFORE:-0}" = 1 ]; then
  echo; echo "== Encodes, worker before the fix (7ef3a99; failures expected)"
  W="$S/before"
  [ -d "$W" ] || git -C "$REPO" worktree add --detach "$W" 7ef3a99 >/dev/null
  cp "$REPO/app/test/integration_soft_telecine_field_based_test.dart" "$W/app/test/"
  ( cd "$W/worker" && cargo build -q 2>/dev/null )
  ( cd "$W/app" && flutter pub get >/dev/null && dart run build_runner build -d >/dev/null 2>&1 \
    && VAPOURBOX_DEPS_DIR="$D" flutter test --tags heavy \
       test/integration_soft_telecine_field_based_test.dart 2>&1 | grep -E "MAD|passed|failed|Expected|Actual" ) || true
fi
