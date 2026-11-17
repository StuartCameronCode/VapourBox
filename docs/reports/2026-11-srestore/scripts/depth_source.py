"""A real 10-bit source vs the same source at 8 bits (task #64).

depth_speed.py shifts the film fixture to 10-bit *after* QTGMC, so the
detector sees the same picture and decides identically. A 10-bit source is
deinterlaced at 10 bits, and QTGMC rounds differently there. This measures
what that does to the detector and the picks, on the film fixture (its exact
10-bit copy, as the heavy test makes it): QTGMC (Slower, double rate) on
each, then Unblend to 23.976, the shipped window of 48.

Metric: luma MAD in 8-bit levels against the nearest original within +-3 of
where the frame belongs (probelib.nearest_truth); a 10-bit frame is compared
after an exact conversion to 8 bits, so it carries up to half a level of
rounding the 8-bit run doesn't. "Clean" is <= 2.0 levels, the heavy test's
limit (score.py's calibrated limits are per fixture and close to it).
"""
import json
import os

import probelib as P
from probelib import core, vs

S = P.srestore
num, den = P.TARGETS['film']

src8 = P.fixture_film_50i()
src10 = core.resize.Point(src8, format=vs.YUV420P10)  # exact: a shift by 2
bob8 = P.bobbed('film')
bob10 = P.cache_raw(P.bob(src10), 'film50p_qtgmc_from10')

# The detector's input: QTGMC's output at each depth.
lu = P.mad(bob8, bob10)
frfac, numr, denm = S.ratio(bob8.fps_num, bob8.fps_den, num, den)
p8 = P.props(bob8, 'film50p_qtgmc')
p10 = P.props(bob10, 'film50p_qtgmc_from10')
names = ['SrBMin', 'SrBMax', 'SrDMax', 'SrMDiff']
props = {}
for k, name in enumerate(names):
    d = [abs(a[k] - b[k]) for a, b in zip(p8, p10)]
    props[name] = {'frames_differing': sum(1 for v in d if v > 0), 'max_abs_diff': max(d)}
d8 = P.decisions_window(p8, frfac, numr, denm, 48)
d10 = P.decisions_window(p10, frfac, numr, denm, 48)
flipped = [n for n in range(len(d8)) if d8[n] != d10[n]]

gt = P.truth(P.TRUTH_COUNT['film'])
o8 = S.unblend(bob8, num, den)
o10 = S.unblend(bob10, num, den)
n8 = P.nearest_truth(o8, gt, 1.0, search=3)
n10 = P.nearest_truth(o10, gt, 1.0, search=3)
same = [m for m in range(len(n8)) if n8[m][0] == n10[m][0]]
moved = [{'output': m, 'pick8': n8[m][0], 'pick10': n10[m][0]} for m in range(len(n8)) if m not in same]
od = P.mad(o8, o10)
od_same = sorted(od[m] for m in same)


def clean(picks, limit):
    return sum(1 for _, v, _ in picks if v <= limit)


res = {
    'qtgmc_output_luma_mad_8_vs_10': {'median': sorted(lu)[len(lu) // 2], 'max': max(lu)},
    'detector_props': props,
    'decisions': {'frames': len(d8), 'differing': len(flipped), 'at': flipped},
    'output_frames': len(n8),
    'same_original': len(same),
    'moved_to_a_neighbour': moved,
    'luma_8_vs_10_where_same': {'median': od_same[len(od_same) // 2], 'max': od_same[-1]},
    'worst_8_vs_10_frame': max(od),
    'clean_le_2.0': {'8bit': clean(n8, 2.0), '10bit': clean(n10, 2.0)},
    'clean_le_1.5': {'8bit': clean(n8, 1.5), '10bit': clean(n10, 1.5)},
    'worst_to_truth': {'8bit': max(v for _, v, _ in n8), '10bit': max(v for _, v, _ in n10)},
    'distinct_originals': {'8bit': len({i for i, _, _ in n8}), '10bit': len({i for i, _, _ in n10}),
                           'of': P.TRUTH_COUNT['film']},
}
print(json.dumps(res, indent=1))
json.dump(res, open(os.path.join(P.HERE, '..', 'data', 'depth_source.json'), 'w'), indent=1)
