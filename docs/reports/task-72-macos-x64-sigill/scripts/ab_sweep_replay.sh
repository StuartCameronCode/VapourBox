#!/usr/bin/env bash
# Task #72: replay captured push-gate format-sweep vspipe runs with R78's own
# vspipe and with the patched one (task #68), in the same deps bundle.
# Run from the repository root:
#
#   ab_sweep_replay.sh <vapoursynth-dir> <patched-vspipe-bin> <capture-dir> <repeat> <parallel> <out-dir>
#
# <vapoursynth-dir>  deps/<platform>/vapoursynth of an UNPATCHED bundle
#                    (1.17.0-rc3), after `.github/scripts/replay-vspipe.sh
#                    install` captured the format sweep's runs into
#                    <capture-dir> (it moved the bundle's own vspipe-bin to
#                    vspipe-bin.real)
# <patched-vspipe-bin>  vspipe-bin from a 1.18.0 bundle
#
# Only vspipe-bin.real changes between the two sides. Each side replays every
# captured run <repeat> times, <parallel> at once (replay-vspipe.sh run,
# plain mode), and the exit codes are tallied: 132 = SIGILL, 134 = SIGABRT,
# 139 = SIGSEGV. On macOS each new crash report is classified with
# print-crash-reports.py --classify; on Linux, print-crash-reports.py runs
# gdb over the newest cores (enable-core-dumps.sh) after each side.
# Writes <out-dir>/summary.txt.
set -u
VSDIR="$1"; PATCHED="$2"; CAP="$3"; REPEAT="$4"; PAR="$5"; OUT="$6"
REPO="$(pwd)"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
REAL="$VSDIR/vspipe-bin.real"
[ -f "$REAL" ] || { echo "no $REAL: run replay-vspipe.sh install first" >&2; exit 2; }
cp "$REAL" "$OUT/vspipe-unpatched.bin"
restore() { cp "$OUT/vspipe-unpatched.bin" "$REAL"; }
trap restore EXIT
MARK='VapourBox patch: vspipe frame-done count'
REPORTS="$HOME/Library/Logs/DiagnosticReports"

for side in unpatched patched; do
  if [ "$side" = patched ]; then cp "$PATCHED" "$REAL"; else cp "$OUT/vspipe-unpatched.bin" "$REAL"; fi
  chmod +x "$REAL"
  [ "$(uname -s)" = Darwin ] && codesign -s - -f "$REAL" >/dev/null 2>&1
  if grep -aq "$MARK" "$REAL"; then fix=yes; else fix=no; fi
  touch "$OUT/$side.stamp"; sleep 1
  bash .github/scripts/replay-vspipe.sh run "$VSDIR" "$CAP" "$REPEAT" "$PAR" plain "$OUT/$side" > "$OUT/$side.log" 2>&1
  cat "$OUT/$side.log"
  total=$(wc -l < "$OUT/$side/results.tsv" | tr -d ' ')
  codes=$(awk -F'\t' '$3 != 0 {c[$3]++} END {for (k in c) printf "%s exit %s; ", c[k], k}' "$OUT/$side/results.tsv")
  failed=$(awk -F'\t' '$3 != 0' "$OUT/$side/results.tsv" | wc -l | tr -d ' ')
  line="sweep $side (fix marker: $fix): runs=$total failures=$failed ${codes:+($codes)}"
  if [ -d "$REPORTS" ]; then
    find "$REPORTS" -name 'vspipe-bin*.ips' -newer "$OUT/$side.stamp" -exec cp {} "$OUT/$side/" \;
    shopt -s nullglob; ips=( "$OUT/$side"/*.ips ); shopt -u nullglob
    if [ ${#ips[@]} -gt 0 ]; then
      python3 -I .github/scripts/print-crash-reports.py --classify "${ips[@]}" > "$OUT/$side/classified.tsv"
      line="$line; crash reports: $(cut -f2 "$OUT/$side/classified.tsv" | sort | uniq -c | awk '{printf "%s %s, ", $1, $2}')"
    fi
  elif [ "$(uname -s)" = Linux ]; then
    python3 .github/scripts/print-crash-reports.py > "$OUT/$side/cores.txt" 2>&1
    line="$line; cores: $(grep -c '^  => ' "$OUT/$side/cores.txt") classified ($(grep -o 'teardown race' "$OUT/$side/cores.txt" | wc -l | tr -d ' ') the race)"
    sudo rm -f "${VAPOURBOX_CORE_DIR:-/tmp/cores}"/core* 2>/dev/null  # root's, in a sticky dir
  fi
  echo "$line" | tee -a "$OUT/summary.txt"
done
cat "$OUT/summary.txt"
