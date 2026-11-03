#!/bin/bash
# Reproduce every number in the issue #144 report (macOS arm64; any platform
# with an OpenCL GPU and a deps bundle should work with DEPS adjusted).
#
#   KNLM_PROBE_DIR=/some/scratch ./run.sh [PLUGIN ...]
#
# With no PLUGIN arguments it compares the bundle's own knlm with the
# KNLMeansCL 1.3 PyPI wheel, downloaded into $KNLM_PROBE_DIR and checked by
# hash. Give plugin paths to compare those instead, e.g. the deps-1.14.0
# libknlmeanscl.dylib (Khanattila master) against a v1.3 build.
#
# Each plugin runs in its own process: knlm_depth_probe.py dumps frames there,
# knlm_compare.py diffs them, nlm_reference.py checks the maths.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
: "${KNLM_PROBE_DIR:?set KNLM_PROBE_DIR to a scratch directory}"
mkdir -p "$KNLM_PROBE_DIR"

case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) DEPS="${DEPS:-$REPO/deps/macos-arm64}"
                  WHEEL_TAG=macosx_15_0_arm64
                  WHEEL_SHA=78a044c24f9a185159990f3127040d3db2d354dce2235f7362a811211c8fa96b ;;
    *) echo "set DEPS and pass plugin paths explicitly on this platform" >&2
       DEPS="${DEPS:?}"; WHEEL_TAG=""; WHEEL_SHA="" ;;
esac

if [ $# -eq 0 ]; then
    [ -n "$WHEEL_TAG" ] || { echo "no wheel known for this platform" >&2; exit 1; }
    W="$KNLM_PROBE_DIR/wheel"; mkdir -p "$W"
    url=$(curl -fsS https://pypi.org/pypi/vapoursynth-knlmeanscl/1.3/json | python3 -c \
        "import sys,json;print([f['url'] for f in json.load(sys.stdin)['urls'] if '$WHEEL_TAG' in f['filename']][0])")
    curl -fsSL -o "$W/k.whl" "$url"
    echo "$WHEEL_SHA  $W/k.whl" | shasum -a 256 -c -
    (cd "$W" && unzip -o -q k.whl)
    set -- "" "$(find "$W/vapoursynth/plugins" -name '*KNLMeansCL*' | head -1)"
fi

export PYTHONHOME="$DEPS/python" PYTHONPATH="$DEPS:$DEPS/python-packages"
export DYLD_LIBRARY_PATH="$DEPS/vapoursynth:$DEPS/python/lib" XDG_CONFIG_HOME="$DEPS/config"
PY="$DEPS/python/bin/python3"

dirs=()
i=0
for plugin in "$@"; do
    name="build$i"; [ -z "$plugin" ] && name="bundle"
    for run in a b; do
        out="$KNLM_PROBE_DIR/$name-$run"; rm -rf "$out"
        "$PY" "$HERE/knlm_depth_probe.py" --out "$out" ${plugin:+--alt "$plugin"} >/dev/null
    done
    dirs+=("$KNLM_PROBE_DIR/$name-a")
    echo "== $name (${plugin:-bundle knlm}): CPU reference"
    "$PY" "$HERE/nlm_reference.py" ${plugin:+"$plugin"}
    echo "== $name: repeat run, distinct differences (0.0000 = repeatable)"
    env -u PYTHONHOME -u PYTHONPATH python3 "$HERE/knlm_compare.py" \
        "$KNLM_PROBE_DIR/$name-a" "$KNLM_PROBE_DIR/$name-b" | tail -n +2 | awk -F'|' '{print $NF}' | sort | uniq -c
    i=$((i + 1))
done
if [ ${#dirs[@]} -eq 2 ]; then
    echo "== depth matrix, first vs second"
    env -u PYTHONHOME -u PYTHONPATH python3 "$HERE/knlm_compare.py" "${dirs[0]}" "${dirs[1]}"
fi
