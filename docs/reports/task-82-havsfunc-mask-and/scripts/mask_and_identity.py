"""Task #82: is Expr 'x y min' havsfunc's Lut2(function=lambda x, y: x & y)?

Needs a havsfunc with patch 8 (its eight mask ANDs go through _mask_and);
the other two variants are swapped in by replacing haf._mask_and:
  upstream  core.std.Lut2(a, b, function=lambda x, y: x & y)  (havsfunc r31)
  lut       core.std.Lut2(a, b, lut=[x & y ...])               (task #75's memo)
  expr      havsfunc's _mask_and, Expr 'x y min'                 (patch 8;
            akarin's Expr where the bundle has akarin)
  std_expr  VapourSynth's own std.Expr 'x y min', what a bundle without
            akarin (macOS x64) runs

1. Exhaustive: x & y == min(x, y) for every x and y in {0, peak}, 8 and 10 bits.
2. End to end: LUTDeCrawl and LUTDeRainbow (linkUV on and off), output and
   mask=True, at 8 and 10 bits and 4:2:0/4:2:2/4:4:4, against upstream.
3. Evaluation time of one call (building the graph, no frames), median of 5.

Prints one JSON object. Run with bundle_python.sh.
"""
import json
import platform
import statistics
import time

import vapoursynth as vs
import havsfunc as haf

core = vs.core
assert hasattr(haf, '_mask_and'), 'needs a havsfunc with patch 8 (task #82)'
EXPR = haf._mask_and


def upstream(a, b):
    return core.std.Lut2(a, b, function=lambda x, y: x & y)


def lut(a, b):
    ba, bb = a.format.bits_per_sample, b.format.bits_per_sample
    return core.std.Lut2(a, b, lut=[x & y for y in range(1 << bb) for x in range(1 << ba)])


def std_expr(a, b):
    return vs.core.std.Expr([a, b], ['x y min'])


VARIANTS = {'upstream': upstream, 'lut': lut, 'expr': EXPR, 'std_expr': std_expr}

CALLS = {
    'LUTDeCrawl': lambda c, m: haf.LUTDeCrawl(c, ythresh=10, cthresh=10, maxdiff=50, mask=m),
    'LUTDeRainbow': lambda c, m: haf.LUTDeRainbow(c, cthresh=10, ythresh=10, y=True, linkUV=True, mask=m),
    'LUTDeRainbow unlinked': lambda c, m: haf.LUTDeRainbow(c, cthresh=10, ythresh=10, y=True, linkUV=False, mask=m),
}

FORMATS = (vs.YUV420P8, vs.YUV422P8, vs.YUV444P8, vs.YUV420P10, vs.YUV422P10, vs.YUV444P10)


def fixture(fmt):
    # Mid grey with grain that changes every frame, plus a static band, so
    # every mask is partly set: both branches of every AND are exercised.
    f = core.get_video_format(fmt)
    mid = 1 << (f.bits_per_sample - 1)
    c = core.std.BlankClip(width=720, height=480, format=fmt, length=6, color=[mid] * 3)
    g = core.grain.Add(c, var=40, uvar=40, constant=False, seed=3)
    return core.std.StackVertical([g.std.Crop(bottom=160), c.std.Crop(top=320)])


def same(a, b):
    if a.format.id != b.format.id or (a.width, a.height, a.num_frames) != (b.width, b.height, b.num_frames):
        return False
    for p in range(a.format.num_planes):
        st = core.std.PlaneStats(a, b, plane=p)
        if any(st.get_frame(n).props['PlaneStatsDiff'] != 0 for n in range(a.num_frames)):
            return False
    return True


def build(variant, call, clip, mask):
    haf._mask_and = VARIANTS[variant]
    try:
        t = time.perf_counter()
        out = call(clip, mask)
        return out, time.perf_counter() - t
    finally:
        haf._mask_and = EXPR


out = {'machine': platform.machine(), 'vapoursynth': vs.__version__,
       'akarin': hasattr(core, 'akarin'), 'exhaustive': {}, 'identical': [], 'eval_seconds': {}}

for bits in (8, 10):
    peak = (1 << bits) - 1
    bad = [(x, y) for x in range(peak + 1) for y in (0, peak)
           if (x & y) != min(x, y) or (y & x) != min(y, x)]
    out['exhaustive'][bits] = not bad

for fmt in FORMATS:
    clip = fixture(fmt)
    name = core.get_video_format(fmt).name
    for label, call in CALLS.items():
        for mask in (False, True):
            want, _ = build('upstream', call, clip, mask)
            got, _ = build('expr', call, clip, mask)
            got_std, _ = build('std_expr', call, clip, mask)
            row = {'format': name, 'call': label, 'what': 'mask' if mask else 'output',
                   'identical': same(got, want), 'identical_std_expr': same(got_std, want)}
            if mask:
                row['mask_average'] = round(core.std.PlaneStats(got).get_frame(2).props['PlaneStatsAverage'], 3)
            out['identical'].append(row)

for fmt in (vs.YUV422P8, vs.YUV422P10):
    clip = fixture(fmt)
    name = core.get_video_format(fmt).name
    for label in ('LUTDeCrawl', 'LUTDeRainbow'):
        for variant in VARIANTS:
            times = [build(variant, CALLS[label], clip, False)[1] for _ in range(5)]
            out['eval_seconds']['%s %s %s' % (name, label, variant)] = round(statistics.median(times), 4)

print(json.dumps(out, indent=1))
