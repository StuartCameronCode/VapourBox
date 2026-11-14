"""The mechanism on hard_telecine_test.avi, in ffmpeg's own words:
  1. its first packets: DTS 0,1,2 ... (decode order), PTS only on B packets
  2. its first decoded frames: best-effort timestamps 1,2,3 ... (display k at k+1)
  3. a -copyts accurate seek to frame 10 at (10 - 0.5)/fps printed %.6f keeps a
     frame stamped 9 (display 8): the half-tick tie, printed below the half
  4. a seek to frame 1: "could not seek", decoding resumes at display 45

  python3 timestamps.py [source]"""
import os
import subprocess
import sys
from avilib import FF, RES, ffprobe_json

src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(RES, 'hard_telecine_test.avi')
tb = 1001 / 30000

print('packets (decode order): dts, pts')
for p in ffprobe_json('-select_streams', 'v:0', '-show_entries', 'packet=pts,dts,flags',
                      '-read_intervals', '%+#10', src)['packets']:
    print(f"  dts {p.get('dts', 'N/A'):>3}  pts {p.get('pts', 'N/A'):>3}  {p.get('flags')}")

print('decoded frames (display order): best-effort timestamp, picture type')
for i, f in enumerate(ffprobe_json('-select_streams', 'v:0', '-show_entries',
                                   'frame=best_effort_timestamp,pict_type',
                                   '-read_intervals', '%+#10', src)['frames'][:8]):
    print(f"  display {i}: ts {f.get('best_effort_timestamp')}  {f.get('pict_type')}")


def showinfo(args):
    err = subprocess.run([FF, '-hide_banner', *args, '-map', '0:v:0', '-frames:v', '2',
                          '-fps_mode', 'passthrough', '-vf', 'showinfo', '-f', 'null', '-'],
                         capture_output=True, text=True).stderr
    lines = [l for l in err.splitlines() if 'pts:' in l or 'could not seek' in l]
    return [l[l.index('pts:'):l.index('pts_time') - 1].strip() if 'pts:' in l else l.strip()
            for l in lines]


for n in (10, 41, 43):
    ss = f'{(n - 0.5) * tb:.6f}'
    print(f'-copyts -ss {ss} (frame {n}, {float(ss) / tb:.6f} ticks): first kept {showinfo(["-copyts", "-ss", ss, "-i", src])}')
print(f'-ss {0.5 * tb:.6f} (frame 1): {showinfo(["-ss", f"{0.5 * tb:.6f}", "-i", src])}')
