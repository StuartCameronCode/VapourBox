#!/usr/bin/env bash
# Run vspipe on a script N times and count the runs that fail (task #68).
#
#   vspipe_loop.sh <vspipe> <script.vpy> <runs>
#
# Each failure prints "FAIL rc=<status> <first stderr line>". The last line is
# "runs=N failures=M". y4m output goes to a file that is thrown away (not
# /dev/null, which Windows' vspipe cannot open by that name).
set -u
V="$1"; S="$2"; N="$3"
TMP="$(mktemp -d)"
fails=0
for i in $(seq 1 "$N"); do
  "$V" -c y4m "$S" "$TMP/out.y4m" 2> "$TMP/err"
  rc=$?
  if [ $rc -ne 0 ]; then
    fails=$((fails + 1))
    echo "FAIL rc=$rc $(head -n1 "$TMP/err")"
  fi
done
rm -rf "$TMP"
echo "runs=$N failures=$fails"
