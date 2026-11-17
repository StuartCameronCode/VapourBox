"""What the padding does to a job that ran before (task #57).

The calls whose plugin refused 4:2:0 720x486 only when field-flagged ran on a
progressive one before. Their contracts are field_based_only, so a progressive
frame takes the unpadded path, chosen per frame. This compares the plugin
alone with the call through run_within() on progressive 4:2:0 720x486, 8 and
16-bit: mean and max absolute difference (8-bit levels) over the rows above
the bottom 16, and over the bottom 16. 'self' is the plugin alone against a
second run of itself, the floor for a call that is not deterministic.

(The first version padded every frame: LSFmod then differed by up to 26
levels inside the frame, since it supersamples at a size that follows the
height. That is why the contracts are field_based_only.)
"""
import json

import vapoursynth as vs

from common import clip, probe_calls
import plugin_formats as pf

core = vs.core
CALLS = ['dctf.DCTFilter', 'deblock.Deblock', 'havsfunc.Deblock_QED', 'havsfunc.FixChromaBleedingMod',
         'havsfunc.LSFmod', 'sangnom.SangNom', 'temporaldegrain2.TemporalDegrain2']
BOTTOM = 16


def diff(a, b, top, bottom, bits):
    """(mean, max) |a - b| in 8-bit levels over rows [top, h - bottom) of every plane."""
    scale = 1 << (bits - 8)
    total, peak, n = 0.0, 0.0, 0
    for p in range(a.format.num_planes):
        pa = core.std.ShufflePlanes(a, p, vs.GRAY)
        pb = core.std.ShufflePlanes(b, p, vs.GRAY)
        sub = a.format.subsampling_h if p else 0
        t, btm = top >> sub, bottom >> sub
        ca = core.std.Crop(pa, top=t, bottom=btm)
        cb = core.std.Crop(pb, top=t, bottom=btm)
        d = core.std.Expr([ca, cb], 'x y - abs')
        st = core.std.PlaneStats(d)
        for f in st.frames():
            total += f.props['PlaneStatsAverage'] * ((1 << bits) - 1) / scale
            peak = max(peak, f.props['PlaneStatsMax'] / scale)
            n += 1
    return round(total / n, 4), round(peak, 2)


calls = probe_calls()
out = {}
for key in CALLS:
    run = calls[key]['run']
    for bits in (8, 16):
        c = clip('420', bits, 0, 720, 486)
        plain = run(c)
        padded = pf.run_within(c, key, run, delta_only=False)
        again = run(c)
        out['%s %d-bit' % (key, bits)] = {
            'inside': diff(plain, padded, 0, BOTTOM, bits),
            'bottom16': diff(plain, padded, 486 - BOTTOM, 0, bits),
            'self': diff(plain, again, 0, 0, bits),
        }
        print(key, bits, out['%s %d-bit' % (key, bits)], flush=True)
print(json.dumps(out))
