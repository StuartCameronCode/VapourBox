"""§1: what each soft-telecine shape reports to ffprobe, the rate the app
sends for it (FieldOrderDetector.selectFrameRate), its repeat flags, and
whether the Soft Telecine method decimates at that rate.

  python3 rate_probe.py
"""
import json
import subprocess
from gridlib import FP, resource, probe

FILES = ['soft_telecine_test.mkv', 'soft_telecine_dvd.vob', 'soft_telecine_dvd.mkv',
         'hard_telecine_test.avi']


def decimates(fps):  # processing_pipeline::soft_telecine_decimates_at
    return abs(fps - 30000 / 1001) < 0.05 or abs(fps - 30) < 0.05


for f in FILES:
    path = resource(f)
    p = probe(path)
    j = json.loads(subprocess.run([FP, '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                                   'frame=repeat_pict', '-read_intervals', '%+#10', '-of', 'json', path],
                                  capture_output=True, text=True).stdout)
    reps = [fr.get('repeat_pict', 0) for fr in j['frames']]
    print(f"{f:26s} r={p['r']:>11s} avg={p['avg']:>11s} -> app sends {float(p['rate']):.3f}  "
          f"repeat_pict {reps}  Soft Telecine decimates: {decimates(float(p['rate']))}")
