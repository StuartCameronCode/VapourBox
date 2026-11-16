#!/usr/bin/env bash
# Finding 3: where each source's click sits after its flash (picture 5,
# 0.2 s after the picture starts), on the source's own timeline: the sound
# decoded from its start against the container start plus the picture's.
set -euo pipefail
source "$(dirname "$0")/common.sh"
for f in conf_plain.mp4 conf_late_video.ts conf_delayed.avi conf_reset.mpg; do
  fs=$("$FFPROBE" -v error -show_entries format=start_time -of csv=p=0 "$RES/$f")
  vs=$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=start_time -of csv=p=0 "$RES/$f" | head -n1 | tr -d ,)
  as=$("$FFPROBE" -v error -select_streams a:0 -show_entries stream=start_time -of csv=p=0 "$RES/$f" | head -n1 | tr -d ,)
  "$FFMPEG" -v error -i "$RES/$f" -map 0:a:0 -ac 1 -f f32le - | python3 -c "
import struct, sys
b = sys.stdin.buffer.read(); a = struct.unpack('<%df' % (len(b) // 4), b)
i = next(i for i, v in enumerate(a) if abs(v) > 0.3)
click = $as + i / 48000; flash = $vs + 0.2
print('%-20s click %.4f s, flash %.4f s: the click %+.1f ms after it' % ('$f', click, flash, (click - flash) * 1000))"
done
echo "conf_delayed.avi's MP3 packets (24 ms each; the near-start in-point 0.080 s keeps the packet at 0.072):"
"$FFPROBE" -v error -select_streams a:0 -show_entries packet=pts_time,duration_time -of csv=p=0 "$RES/conf_delayed.avi" | sed -n 3,6p
