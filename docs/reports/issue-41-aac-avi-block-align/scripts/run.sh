#!/bin/bash
# Re-runs every local measurement of the report (macOS; the Windows readers
# run on a GitHub runner, see windows/probe-avi-aac-timing.workflow.yml).
#
#   ./run.sh <ffmpeg dir> <VLC binary> <work dir>
#
# e.g. ./run.sh deps/macos-arm64/ffmpeg /Applications/VLC.app/Contents/MacOS/VLC /tmp/issue-41
set -euo pipefail
FF="$1"; VLC="$2"; W="$3"
here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$W/data"
"$FF/ffmpeg" -version | head -n1
python3 -I "$here/sweep.py" "$FF/ffmpeg" "$W/sweep" | tee "$W/data/sweep.jsonl"
FFMPEG="$FF/ffmpeg" python3 -I "$here/windows/make_fixtures.py" "$W/fixtures" > /dev/null
"$here/readers_local.sh" "$FF" "$VLC" "$W/fixtures" | tee "$W/data/readers_local.jsonl"
"$here/odml_check.sh" "$FF" "$W/odml" | tee "$W/data/odml.txt"
