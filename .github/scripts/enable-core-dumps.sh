#!/usr/bin/env bash
# Keep core dumps of crashed processes on a Linux runner, so
# print-crash-reports.py can name the plugin and function a vspipe crash died
# in (task #66: a SIGSEGV in the push gate left nothing but "signal 11").
#
# The kernel pipes each core to a small handler (installed here) instead of
# apport, which drops cores of programs no package owns. A piped core is
# written whatever the process's RLIMIT_CORE, so nothing has to raise
# `ulimit -c` in the shell that runs the tests. The handler keeps at most
# $MAX_CORES cores of at most $MAX_MB MB each and discards the rest, so a crash
# storm (the 11-16 plugin probe crashed dozens of times) can't fill the disk.
#
# Usage: enable-core-dumps.sh [core-dir]   (default $VAPOURBOX_CORE_DIR or /tmp/cores)
# Also installs gdb if it is missing.
set -euo pipefail

CORE_DIR="${1:-${VAPOURBOX_CORE_DIR:-/tmp/cores}}"
MAX_CORES="${MAX_CORES:-5}"
MAX_MB="${MAX_MB:-3072}"
HANDLER=/usr/local/sbin/vapourbox-core-handler

if ! command -v gdb >/dev/null; then
  sudo apt-get install -y --no-install-recommends gdb >/dev/null
fi

sudo mkdir -p "$CORE_DIR"
sudo chmod 1777 "$CORE_DIR"

sudo tee "$HANDLER" >/dev/null <<EOF
#!/bin/sh
# Called by the kernel as root with the core on stdin: %e %p %t.
n=\$(ls "$CORE_DIR" | wc -l)
if [ "\$n" -ge "$MAX_CORES" ]; then cat >/dev/null; exit 0; fi
out="$CORE_DIR/core.\$1.\$2.\$3"
head -c \$(( $MAX_MB * 1024 * 1024 )) > "\$out"
chmod 644 "\$out"
EOF
sudo chmod 755 "$HANDLER"
echo "|$HANDLER %e %p %t" | sudo tee /proc/sys/kernel/core_pattern >/dev/null
# Cores of a process that changed credentials are otherwise suppressed.
sudo sysctl -q -w fs.suid_dumpable=1 || true

echo "core dumps: $(cat /proc/sys/kernel/core_pattern) (keeps $MAX_CORES, up to $MAX_MB MB each)"
echo "gdb: $(gdb --version | head -1)"
