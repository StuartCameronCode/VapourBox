"""What the planner costs: time to create the filter (DFTTest plans in its
constructor, so a preview pays it on every script evaluation), time to the
first frame, and frames per second over the rest. Run it with the PATIENT
bundle and the ESTIMATE one, alternately (one build per process; plans are
cached per process).
argv: [frames]"""
import os
import sys
# Windows' embeddable Python (._pth) does not put the script's folder on sys.path.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import json
import time

from common import CASES, cached, core, fixture, plugin_name

core.num_threads = 8
frames = int(sys.argv[1]) if len(sys.argv) > 1 else 120
res = {}
for w, h in ((720, 480), (1920, 1080)):
    src = cached(fixture(w, h, frames, 8))
    for name in ('nr_default', 'tb1', 'qtgmc_dfttest'):
        t0 = time.perf_counter()
        c = CASES[name](src)
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
print(json.dumps({'plugin': plugin_name(), 'speed': res}, sort_keys=True))
