"""Depth, Expr implementation, and cost.

1. The film fixture after QTGMC, as 8-bit and shifted to 10-bit exactly: the
   detector's measurements and decisions must be identical (it measures an
   8-bit copy of the luma, as upstream does).
2. Measurements through _expr() (akarin's Expr on ARM) vs VapourSynth's own
   std.Expr (what macOS x64 gets): identical or not.
3. Speed at SD (the film fixture scaled to 720x576): QTGMC alone vs QTGMC +
   Unblend, and the cost of one preview frame.
"""
import json
import os
import time

import probelib as P
from probelib import core, vs

S = P.srestore
res = {}

# 1. depth
clip8 = P.bobbed('film')
clip10 = core.resize.Point(clip8, format=vs.YUV420P10)
num, den = P.TARGETS['film']
frfac, numr, denm = S.ratio(clip8.fps_num, clip8.fps_den, num, den)
p8 = [S.props_of(f) for f in S.stats_clip(clip8).frames()]
p10 = [S.props_of(f) for f in S.stats_clip(clip10).frames()]
d8 = P.decisions_window(p8, frfac, numr, denm, 48)
d10 = P.decisions_window(p10, frfac, numr, denm, 48)
o8 = S.unblend(clip8, num, den)
o10 = core.resize.Point(S.unblend(clip10, num, den), format=vs.YUV420P8)
diff = core.std.PlaneStats(o8, o10)
max_diff = max(f.props['PlaneStatsDiff'] for f in diff.frames())
res['depth'] = {'props_identical': p8 == p10, 'decisions_identical': d8 == d10,
                'output_10bit_down_vs_8bit_max_mad': max_diff * 255}
print(res['depth'], flush=True)

# 2. Expr parity
if hasattr(core, 'akarin'):
    src = open(S.__file__).read()
    # The module routes its one Expr through _expr() (akarin here); build a
    # copy forced onto VapourSynth's own std.Expr and compare.
    line = "_akarin_expr = getattr(getattr(core, 'akarin', None), 'Expr', None)"
    assert src.count(line) == 1
    ns = {}
    exec(compile(src.replace(line, '_akarin_expr = None'), 'srestore_std', 'exec'), ns)
    for fx in ('film', 'pal'):
        c = P.bobbed(fx)
        a = [ns['props_of'](f) for f in ns['stats_clip'](c).frames()]
        b = [S.props_of(f) for f in S.stats_clip(c).frames()]
        res[f'expr_{fx}'] = {'props_identical': a == b,
                             'frames_differing': sum(1 for x, y in zip(a, b) if x != y)}
        print(fx, res[f'expr_{fx}'], flush=True)
else:
    res['expr'] = 'akarin not present'

# 3. speed (SD)
def timed(clip, frames=None):
    t = time.perf_counter()
    n = 0
    for _ in (clip.frames() if frames is None else (clip.get_frame(i) for i in frames)):
        n += 1
    return time.perf_counter() - t, n

interlaced = core.resize.Spline36(P.fixture_film_50i(), 720, 576)
interlaced = core.std.SetFieldBased(interlaced, 2)
t_q, n_q = timed(P.bob(interlaced))
t_u, n_u = timed(S.unblend(P.bob(interlaced), num, den))
res['speed_sd'] = {'qtgmc_s': round(t_q, 2), 'qtgmc_frames': n_q, 'qtgmc_unblend_s': round(t_u, 2),
                   'unblend_frames': n_u, 'source_fields_per_s_qtgmc': round(n_q / t_q, 1),
                   'source_fields_per_s_with_unblend': round(n_q / t_u, 1)}
print(res['speed_sd'], flush=True)

# One preview frame: QTGMC over a window of radius r around the target (r =
# the pipeline's floor of 8 source frames for QTGMC alone, 8 + 26 with
# Unblend's 52 double-rate frames), then the pass.
def preview_time(radius_src, with_unblend):
    mid = 75
    win = interlaced[max(0, mid - radius_src):mid + radius_src + 1]
    b = P.bob(win)
    out = S.unblend(b, num, den, origin=0) if with_unblend else b
    t = time.perf_counter()
    out.get_frame(len(out) // 2)
    return round(time.perf_counter() - t, 2)

res['preview_s'] = {'qtgmc_only_radius8': preview_time(8, False),
                    'qtgmc_unblend_radius34': preview_time(34, True)}
print(res['preview_s'], flush=True)
json.dump(res, open(os.path.join(P.SCRATCH, 'depth_speed.json'), 'w'), indent=1)
