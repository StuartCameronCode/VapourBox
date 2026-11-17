#!/bin/bash
# Reproduces every number in ../index.html.
#
#   SCRATCH=/some/scratch/dir DEPS_V3=<bundle with bifrost 3.0> \
#     DEPS_V4=<bundle with bifrost 4.0> WHEELS=<dir with the five 4.0 wheels> ./reproduce.sh
#
# DEPS_V3 is any macOS arm64 bundle up to deps 1.17.0-rc2; DEPS_V4 one built
# by download-deps-macos.sh after task #60 (or a copy of DEPS_V3 with
# vapoursynth/plugins/libbifrost.dylib replaced by the arm64 wheel's
# bifrost.dylib, renamed and re-signed: what the script does). WHEELS holds
# vapoursynth_bifrost-4.0-*.whl as published on PyPI; their SHA-256 are in
# the download-deps-* scripts. Nothing here touches the network.
#
# 1. Static checks of every wheel's binary (static.sh).
# 2. Fixtures: interlaced_test.avi, 12 frames, bicubic to six sizes, as
#    yuv444p16le raw.
# 3. Run to run: probe.py three times per version, in separate processes;
#    compare.py tabulates distinct outputs and v3 = v4 inside whole blocks.
# 4. Accepted depths per version (probe.py depths).
# 5. Parity at depth: probe.py dump on v4, then parity.py.
# 6. Speed: speed.py at 8-bit (both versions) and 16-bit (v4).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
S="${SCRATCH:?set SCRATCH}"
V3="$(cd "${DEPS_V3:?set DEPS_V3}" && pwd)"
V4="$(cd "${DEPS_V4:?set DEPS_V4}" && pwd)"
mkdir -p "$S/fx" "$S/out"

py() {  # py <bundle> args...
  local D="$1"; shift
  PYTHONHOME="$D/python" PYTHONPATH="$D:$D/python-packages" PYTHONNOUSERSITE=1 \
    XDG_CONFIG_HOME="$D/config" "$D/python/bin/python3" "$@"
}

if [ -n "${WHEELS:-}" ]; then
  "$HERE/static.sh" "$WHEELS" "$S/wheels" "$REPO"
fi

FF="$V4/ffmpeg/ffmpeg"
for sz in 96x64 98x64 352x240 718x480 720x480 720x486; do
  "$FF" -hide_banner -loglevel error -y -i "$REPO/Tests/TestResources/interlaced_test.avi" \
    -frames:v 12 -vf "scale=${sz/x/:}:flags=bicubic" -pix_fmt yuv444p16le -f rawvideo "$S/fx/src_$sz.yuv"
done

for r in 1 2 3; do
  py "$V3" "$HERE/probe.py" "$S/fx" "$S/out/v3_$r.json" hashes 2>/dev/null
  py "$V4" "$HERE/probe.py" "$S/fx" "$S/out/v4_$r.json" hashes 2>/dev/null
done
python3 "$HERE/compare.py" "$S/out"

for v in 3 4; do
  D="$V3"; [ $v = 4 ] && D="$V4"
  py "$D" "$HERE/probe.py" "$S/fx" "$S/out/v${v}_depths.json" depths 2>/dev/null
  echo "v$v depths:"; cat "$S/out/v${v}_depths.json"; echo
done

py "$V4" "$HERE/probe.py" "$S/fx" "$S/out/v4dump" dump 2>/dev/null
python3 "$HERE/parity.py" "$S/out/v4dump.d"

echo "v3:"; py "$V3" "$HERE/speed.py" 8 2>/dev/null
echo "v4:"; py "$V4" "$HERE/speed.py" 8 2>/dev/null; py "$V4" "$HERE/speed.py" 16 2>/dev/null
