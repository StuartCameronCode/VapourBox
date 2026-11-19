#!/usr/bin/env bash
# Capture vspipe runs, then replay them many times, to reproduce an
# intermittent native crash (task #66).
#
#   replay-vspipe.sh install <deps-vapoursynth-dir> <match-regex> <capture-dir>
#       Moves the bundle's vspipe-bin to vspipe-bin.real and puts a capturing
#       script in its place (the worker runs vspipe-bin itself, not the vspipe
#       wrapper): every run whose script matches <match-regex> has its
#       script, arguments, environment and stdin saved under
#       <capture-dir>/run.*, then runs as before. Other runs pass through.
#   replay-vspipe.sh uninstall <deps-vapoursynth-dir>
#   replay-vspipe.sh run <deps-vapoursynth-dir> <capture-dir> <repeat> <parallel> <mode> <out-dir>
#       Replays every captured run <repeat> times, <parallel> at once.
#       mode: plain | single-thread (core.num_threads = 1) | valgrind.
#       Writes <out-dir>/results.tsv (iteration, run, exit status) and keeps
#       stderr of every run that failed. Prints a summary; exits 0.
set -uo pipefail

cmd="$1"; shift

case "$cmd" in
install)
  VSDIR="$1"; MATCH="$2"; CAP="$3"
  mkdir -p "$CAP"
  [ -f "$VSDIR/vspipe-bin.real" ] || mv "$VSDIR/vspipe-bin" "$VSDIR/vspipe-bin.real"
  cat > "$VSDIR/vspipe-bin" <<EOF
#!/bin/bash
# task #66 capture script (replay-vspipe.sh); the real one is vspipe-bin.real
REAL="\$(cd "\$(dirname "\$0")" && pwd)/vspipe-bin.real"
script=""
for a in "\$@"; do case "\$a" in *.vpy) script="\$a";; esac; done
if [ -n "\$script" ] && grep -Eq '$MATCH' "\$script" 2>/dev/null; then
  d=\$(mktemp -d "$CAP/run.XXXXXX")
  cp "\$script" "\$d/script.vpy"
  printf '%s\0' "\$@" > "\$d/args"
  # BSD env (macOS 15) may lack -0; perl is on every runner.
  env -0 > "\$d/env" 2>/dev/null || perl -e 'print "\$_=\$ENV{\$_}\0" for keys %ENV' > "\$d/env"
  cat > "\$d/stdin.raw"
  "\$REAL" "\$@" < "\$d/stdin.raw"
  rc=\$?
  echo "\$rc" > "\$d/rc"
  exit "\$rc"
fi
exec "\$REAL" "\$@"
EOF
  chmod +x "$VSDIR/vspipe-bin"
  echo "capture script installed in $VSDIR (match: $MATCH)"
  ;;

uninstall)
  VSDIR="$1"
  [ -f "$VSDIR/vspipe-bin.real" ] && mv -f "$VSDIR/vspipe-bin.real" "$VSDIR/vspipe-bin"
  ;;

run)
  VSDIR="$1"; CAP="$2"; REPEAT="$3"; PAR="$4"; MODE="$5"; OUT="$6"
  mkdir -p "$OUT"
  runs=( "$CAP"/run.* )
  if [ ! -e "${runs[0]}" ]; then echo "no captured runs in $CAP"; exit 0; fi
  VSPIPE="$VSDIR/vspipe-bin.real"
  [ -x "$VSPIPE" ] || VSPIPE="$VSDIR/vspipe-bin"
  for r in "${runs[@]}"; do
    if [ "$MODE" = single-thread ]; then
      { echo 'import vapoursynth as _vb66; _vb66.core.num_threads = 1'; cat "$r/script.vpy"; } > "$r/script.1t.vpy"
    fi
  done
  one() {  # <iteration> <run dir>
    # RV_* names only: the captured environment is loaded below, and it holds
    # whatever the test's own environment held (a workflow's OUT, for one).
    local i="$1" r="$2" script="$2/script.vpy" args=() a rc
    local err="$RV_OUT/err.$(basename "$r").$i"
    [ "$RV_MODE" = single-thread ] && script="$r/script.1t.vpy"
    while IFS= read -r -d '' a; do
      case "$a" in *.vpy) args+=("$script") ;; *) args+=("$a") ;; esac
    done < "$r/args"
    (
      mode="$RV_MODE" vspipe="$RV_VSPIPE" RV_TIMEOUT="$RV_TIMEOUT"
      while IFS= read -r -d '' kv; do export "$kv" 2>/dev/null; done < "$r/env"
      pre=()
      if [ "$mode" = valgrind ]; then
        # The report goes to stderr, kept in the err file whatever the exit.
        export PYTHONMALLOC=malloc
        pre=(valgrind --error-exitcode=99 --track-origins=yes --num-callers=40 --error-limit=no)
      fi
      # GNU timeout where there is one (macOS 15 has none built in).
      tmo=(); [ -n "$RV_TIMEOUT" ] && tmo=("$RV_TIMEOUT" 3600)
      "${tmo[@]}" "${pre[@]}" "$vspipe" "${args[@]}" < "$r/stdin.raw" > /dev/null 2> "$err"
    )
    rc=$?
    printf '%s\t%s\t%s\n' "$i" "$(basename "$r")" "$rc" >> "$RV_OUT/results.tsv"
    [ "$rc" = 0 ] && [ "$RV_MODE" != valgrind ] && rm -f "$err"
    return 0
  }
  export -f one
  export RV_MODE="$MODE" RV_VSPIPE="$VSPIPE" RV_OUT="$OUT"
  RV_TIMEOUT="$(command -v timeout || command -v gtimeout || true)"; export RV_TIMEOUT
  : > "$OUT/results.tsv"
  start=$(date +%s)
  for i in $(seq 1 "$REPEAT"); do for r in "${runs[@]}"; do printf '%s\0%s\0' "$i" "$r"; done; done \
    | xargs -0 -n 2 -P "$PAR" bash -c 'one "$0" "$1"'
  total=$(wc -l < "$OUT/results.tsv")
  failed=$(awk -F'\t' '$3 != 0' "$OUT/results.tsv" | wc -l)
  echo "replay ($MODE): ${#runs[@]} captured run(s) x $REPEAT, $PAR at once: $total runs, $failed failed, $(( $(date +%s) - start )) s"
  awk -F'\t' '$3 != 0 {c[$2" exit "$3]++} END {for (k in c) print "  " c[k] "x " k}' "$OUT/results.tsv"
  for r in "${runs[@]}"; do
    echo "  $(basename "$r"): $(grep -o 'Preset="[A-Za-z ]*"' "$r/script.vpy" | head -1) $(grep -oE '^    (width|height)=[0-9]+|pix_fmt="[a-z0-9]+"' "$r/script.vpy" | head -3 | tr -d ' ' | tr '\n' ' ')"
  done
  ;;
*)
  echo "usage: see the header of $0" >&2; exit 2 ;;
esac
