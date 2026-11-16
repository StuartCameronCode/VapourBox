#!/bin/bash
# Reproduce every number in the report (task #51: a packet index instead of
# time seeks with per-container corrections).
#
# Needs this checkout's debug worker (cd worker && cargo build) and deps for
# ffmpeg/ffprobe (repo deps/<platform> or $VAPOURBOX_DEPS_DIR).
#
#   PKTIDX_WORK    scratch directory (default: a temporary one); the reset
#                  fixtures' joined copies go here
#   PKTIDX_TITLE   a long MPEG-PS title on the internal disk (the report used
#                  a 2 h 16 min PAL DVD's VTS_01_1..5.VOB joined with cat,
#                  4.48 GB); its MKV remux is written next to it
#   PKTIDX_VOBS    the same title's VOB parts on a network share (one cold
#                  read per part per probe), space-separated
#   PKTIDX_NAS_MKV two other large MKVs on the share, space-separated (one
#                  cold full read each, never read before)
#
# Steps without their inputs are skipped. Results go to ../data/*.json.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export PKTIDX_WORK="${PKTIDX_WORK:-$(mktemp -d)}"
mkdir -p "$PKTIDX_WORK"
cd "$HERE"

python3 check_today.py                       # the control is today's code
python3 sweep_probe.py                       # B: every start of every fixture
python3 count_probe.py                       # B: frame count from the index

if [ -n "${PKTIDX_VOBS:-}" ]; then           # A: cold, on the share
  # shellcheck disable=SC2086
  python3 cost_probe.py cold $PKTIDX_VOBS
  python3 cost_probe.py windows "2 h DVD title (VOB set) on the NAS" "concat:$(echo $PKTIDX_VOBS | tr ' ' '|')"
fi
if [ -n "${PKTIDX_NAS_MKV:-}" ]; then
  set -- $PKTIDX_NAS_MKV
  python3 cost_probe.py one "index, video only" "$1"
  python3 cost_probe.py one "read (cat)" "$2"
  python3 cost_probe.py windows "1080p H.264 MKV on the NAS (cold)" "$2"
fi
if [ -n "${PKTIDX_TITLE:-}" ]; then          # A, B and C on the long title
  MKV="${PKTIDX_TITLE%.*}.mkv"
  python3 cost_probe.py warm "2 h PAL DVD title, MPEG-PS, internal SSD" "$PKTIDX_TITLE" 5
  "${VAPOURBOX_DEPS_DIR:-../../../../deps/macos-arm64}/ffmpeg/ffmpeg" -v error -fflags +genpts \
    -i "$PKTIDX_TITLE" -map 0:v -map 0:a -c copy -y "$MKV"
  python3 cost_probe.py warm "the same title remuxed to MKV, internal SSD" "$MKV" 5
  python3 long_title_check.py "$PKTIDX_TITLE"
  python3 latency_probe.py "2 h DVD title (MPEG-PS), internal SSD" "$PKTIDX_TITLE"
  python3 latency_probe.py "the same title as MKV, internal SSD" "$MKV"
fi
python3 retire_count.py                      # D
echo "Results in $HERE/../data"
