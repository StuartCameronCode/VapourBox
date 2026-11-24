#!/usr/bin/env bash
# Keep what vspipe writes to the encoder (task #99, B2).
#
#   capture-vspipe-stdout.sh install <deps-vapoursynth-dir> <capture-dir>
#       Moves the bundle's vspipe-bin to vspipe-bin.real and puts a script in
#       its place (the worker runs vspipe-bin itself) that runs the real one
#       and copies its stdout, the Y4M the encoder reads, to
#       <capture-dir>/run.*/out.y4m, with its script and exit status.
#   capture-vspipe-stdout.sh uninstall <deps-vapoursynth-dir>
#
# The copy goes through `tee`, so the encoder still reads vspipe as it runs.
set -uo pipefail
cmd="$1"; VSDIR="$2"
case "$cmd" in
install)
  CAP="$3"; mkdir -p "$CAP"
  [ -f "$VSDIR/vspipe-bin.real" ] || mv "$VSDIR/vspipe-bin" "$VSDIR/vspipe-bin.real"
  cat > "$VSDIR/vspipe-bin" <<EOF
#!/bin/bash
# task #99 capture script (capture-vspipe-stdout.sh); the real one is vspipe-bin.real
set -o pipefail
REAL="\$(cd "\$(dirname "\$0")" && pwd)/vspipe-bin.real"
d=\$(mktemp -d "$CAP/run.XXXXXX")
for a in "\$@"; do case "\$a" in *.vpy) cp "\$a" "\$d/script.vpy";; esac; done
"\$REAL" "\$@" | tee "\$d/out.y4m"
rc=\$?
echo "\$rc" > "\$d/rc"
exit "\$rc"
EOF
  chmod +x "$VSDIR/vspipe-bin"
  echo "capture script installed in $VSDIR"
  ;;
uninstall)
  [ -f "$VSDIR/vspipe-bin.real" ] && mv -f "$VSDIR/vspipe-bin.real" "$VSDIR/vspipe-bin"
  ;;
esac
