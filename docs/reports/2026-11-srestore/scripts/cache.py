"""Why stats_clip pins its own cache (std.SetVideoCache).

Counts how many times each QTGMC output frame is computed for an SD encode
(the film fixture scaled to 720x576), with the module as shipped and with the
SetVideoCache line removed, and the time each takes.
"""
import collections
import json
import os
import time

import probelib as P
from probelib import core

S = P.srestore
interlaced = core.std.SetFieldBased(core.resize.Spline36(P.fixture_film_50i(), 720, 576), 2)
count = collections.Counter()


def spy(n, f):
    count[n] += 1
    return f


def run(unblend):
    count.clear()
    q = P.bob(interlaced)
    q = core.std.ModifyFrame(q, q, spy)
    out = unblend(q, 24000, 1001) if unblend else q
    t = time.perf_counter()
    n = sum(1 for _ in out.frames())
    return {'seconds': round(time.perf_counter() - t, 2), 'output_frames': n,
            'qtgmc_frames_computed': sum(count.values()), 'max_per_frame': max(count.values())}


src = open(S.__file__).read()
line = '    core.std.SetVideoCache(stats,'
assert src.count(line) == 1
ns = {}
exec(compile(src.replace(line, '    (lambda *a, **k: None)(stats,'), 'srestore_nocache', 'exec'), ns)

res = {'qtgmc_alone': run(None), 'with_unblend': run(S.unblend), 'with_unblend_no_cache_pin': run(ns['unblend'])}
for k, v in res.items():
    print(k, v)
json.dump(res, open(os.path.join(P.SCRATCH, 'cache.json'), 'w'), indent=1)
