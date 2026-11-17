#!/usr/bin/env bash
# Capture vspipe runs, then replay them many times, to reproduce an
# intermittent native crash (task #66).
#
#   replay-vspipe.sh install <deps-vapoursynth-dir> <match-regex> <capture-dir>
#       Moves the bundle's vspipe wrapper to vspipe.orig and puts a capturing
#       wrapper in its place: every run whose script matches <match-regex>
#       has its script, arguments, environment and stdin saved under
#       <capture-dir>/run.*, then runs as before. Other runs pass through.
#       Also writes vspipe.valgrind (memcheck around vspipe-bin).
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
  [ -f "$VSDIR/vspipe.orig" ] || mv "$VSDIR/vspipe" "$VSDIR/vspipe.orig"
  cat > "$VSDIR/vspipe" <<EOF
#!/bin/bash
# task #66 capture wrapper (replay-vspipe.sh); the bundle's own is vspipe.orig
SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
script=""
for a in "\$@"; do case "\$a" in *.vpy) script="\$a";; esac; done
if [ -n "\$script" ] && grep -Eq '$MATCH' "\$script" 2>/dev/null; then
  d=\$(mktemp -d "$CAP/run.XXXXXX")
  cp "\$script" "\$d/script.vpy"
  printf '%s\0' "\$@" > "\$d/args"
  env -0 > "\$d/env"
  cat > "\$d/stdin.raw"
  "\$SCRIPT_DIR/vspipe.orig" "\$@" < "\$d/stdin.raw"
  rc=\$?
  echo "\$rc" > "\$d/rc"
  exit "\$rc"
fi
exec "\$SCRIPT_DIR/vspipe.orig" "\$@"
EOF
  chmod +x "$VSDIR/vspipe"
  sed 's|^exec "\$SCRIPT_DIR/vspipe-bin" "\$@"$|exec valgrind --error-exitcode=99 --track-origins=yes --num-callers=40 --error-limit=no --log-file="${VB_VALGRIND_LOG:-/tmp/vg}.%p.log" "$SCRIPT_DIR/vspipe-bin" "$@"|' \
    "$VSDIR/vspipe.orig" > "$VSDIR/vspipe.valgrind"
  chmod +x "$VSDIR/vspipe.valgrind"
  grep -q valgrind "$VSDIR/vspipe.valgrind" || { echo "could not write vspipe.valgrind: the wrapper's exec line changed" >&2; exit 1; }
  echo "capture wrapper installed in $VSDIR (match: $MATCH)"
  ;;

uninstall)
  VSDIR="$1"
  [ -f "$VSDIR/vspipe.orig" ] && mv -f "$VSDIR/vspipe.orig" "$VSDIR/vspipe"
  ;;

run)
  VSDIR="$1"; CAP="$2"; REPEAT="$3"; PAR="$4"; MODE="$5"; OUT="$6"
  mkdir -p "$OUT"
  runs=( "$CAP"/run.* )
  if [ ! -e "${runs[0]}" ]; then echo "no captured runs in $CAP"; exit 0; fi
  case "$MODE" in
    valgrind) VSPIPE="$VSDIR/vspipe.valgrind" ;;
    *)        VSPIPE="$VSDIR/vspipe.orig" ;;
  esac
  for r in "${runs[@]}"; do
    if [ "$MODE" = single-thread ]; then
      { echo 'import vapoursynth as _vb66; _vb66.core.num_threads = 1'; cat "$r/script.vpy"; } > "$r/script.1t.vpy"
    fi
  done
  one() {  # <iteration> <run dir>
    local i="$1" r="$2" script="$2/script.vpy" args=() a rc
    [ "$MODE" = single-thread ] && script="$r/script.1t.vpy"
    while IFS= read -r -d '' a; do
      case "$a" in *.vpy) args+=("$script") ;; *) args+=("$a") ;; esac
    done < "$r/args"
    (
      while IFS= read -r -d '' kv; do export "$kv" 2>/dev/null; done < "$r/env"
      export VB_VALGRIND_LOG="$OUT/vg.$(basename "$r").$i"
      [ "$MODE" = valgrind ] && export PYTHONMALLOC=malloc
      timeout 3600 "$VSPIPE" "${args[@]}" < "$r/stdin.raw" > /dev/null 2> "$OUT/err.$(basename "$r").$i"
    )
    rc=$?
    printf '%s\t%s\t%s\n' "$i" "$(basename "$r")" "$rc" >> "$OUT/results.tsv"
    [ "$rc" = 0 ] && rm -f "$OUT/err.$(basename "$r").$i"
    return 0
  }
  export -f one; export MODE VSPIPE OUT
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
