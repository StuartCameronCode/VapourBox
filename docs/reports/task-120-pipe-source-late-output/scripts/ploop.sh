#!/bin/bash
id=$1; n=$2
for i in $(seq 1 $n); do
  s=$(date +%s)
  timeout 60 $VSPIPE pitch.vpy -c y4m - < raw444.yuv > /dev/null 2> P/$id-$i.err; rc=$?
  e=$(( $(date +%s) - s ))
  echo "$id-$i rc=$rc secs=$e"
done
