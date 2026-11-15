#!/bin/bash
# Reproduces every number in ../index.html.
#
#   [DEPS=deps/macos-arm64] ./reproduce.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
D="$(cd "${DEPS:-$REPO/deps/macos-arm64}" && pwd)"
PYTHONHOME="$D/python" PYTHONPATH="$D:$D/python-packages" PYTHONNOUSERSITE=1 \
  XDG_CONFIG_HOME="$D/config" "$D/python/bin/python3" "$HERE/sweep.py"
