#!/bin/bash
# loop.sh <id> <count>: run the instrumented stab script count times, report re-requests and failures
id=$1; n=$2
for i in $(seq 1 $n); do
  VB_LOG=$PWD/L/$id-$i.log $VSPIPE stab.vpy -c y4m - < raw.yuv > /dev/null 2> L/$id-$i.err || echo "FAIL $id-$i"
done
