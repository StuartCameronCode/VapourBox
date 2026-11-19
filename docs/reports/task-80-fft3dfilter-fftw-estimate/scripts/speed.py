"""What measure costs: time to create the filter (FFTW plans in its
constructor, so a preview pays it on every script evaluation), time to the
first frame, and frames per second over the rest.
argv: measure (0 | 1 | default) [frames]. One measure per process (plans
are cached per process)."""
import os
import sys
# Windows' embeddable Python (._pth) does not put the script's folder on sys.path.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import json
import sys
import time

from common import CASES, core, fixture, parse_measure

core.num_threads = 8
measure = parse_measure(sys.argv[1])
frames = int(sys.argv[2]) if len(sys.argv) > 2 else 60
res = {}
for w, h in ((720, 480), (1920, 1080)):
    src = fixture(w, h, frames, 8)
    # Read the source once so its decode is not timed.
    for _ in src.frames(prefetch=16):
        pass
    for name, fn in CASES.items():
        t0 = time.perf_counter()
        c = fn(src, measure)
        t1 = time.perf_counter()
        c.get_frame(0)
        t2 = time.perf_counter()
        n = 0
        for _ in c[1:].frames(prefetch=16):
            n += 1
        t3 = time.perf_counter()
        res['%s %dx%d' % (name, w, h)] = {
            'create_s': round(t1 - t0, 4), 'first_frame_s': round(t2 - t1, 4),
            'fps': round(n / (t3 - t2), 2)}
print(json.dumps({'measure': sys.argv[1], 'speed': res}, sort_keys=True))
