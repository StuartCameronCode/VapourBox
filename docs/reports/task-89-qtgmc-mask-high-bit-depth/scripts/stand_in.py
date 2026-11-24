"""Task #89: does plugin_formats.havsfunc_mask_any_depth (the shipped helper,
imported from worker/templates) give a deep QTGMC InputType 2/3 job the
8-bit job's picture, to within QTGMC's own depth rounding?

A. Mask alone, on the same picture at 8 and 10 bits, pel 1 and pel 2.
B. QTGMC InputType 2/3 at Slow, Medium, Placebo: 8-bit through the helper
   vs plain havsfunc (and plain twice, for determinism), 10-bit (exact x4
   and real) vs 8-bit, with a control: the same comparison with the Mask
   off (ProgSADMask=0), and what the Mask changes at all at 8 bits.
C. Other formats and High Precision run.
Mean / max luma differences in 8-bit levels (B, C) or mask levels (A).
"""
import sys
import time

import vapoursynth as vs
import havsfunc as haf

from common import core, sources, low_bits, stats
import plugin_formats as pf

src10r, src8, src10x = sources()
print('real low bits (mean |10-bit - rounded 8-bit x4|, 10-bit levels):', round(low_bits(src10r, src10x), 3))

# Every mask the helper makes, captured (the proxy looks the function up on
# each call, so wrapping the module attribute sees havsfunc's calls too).
CAPTURED = []
_shipped = pf.mvtools_mask_any_depth


def _capture(clip, vectors, **kw):
    m = _shipped(clip, vectors, **kw)
    CAPTURED.append(m)
    return m


pf.mvtools_mask_any_depth = _capture


def qtgmc(c, **kw):
    return pf.havsfunc_mask_any_depth(haf, lambda x: haf.QTGMC(x, **kw))(c)


# --- A ---------------------------------------------------------------------
for pel in (1, 2):
    def vecs(c):
        return core.mv.Analyse(core.mv.Super(c, pel=pel), isb=True, delta=1, blksize=16, overlap=8)
    m8 = core.mv.Mask(src8, vecs(src8), kind=1, ml=10)
    mx = _shipped(src10x, vecs(src10x), kind=1, ml=10)
    print('A pel=%d  mask, 10-bit x4 picture through the stand-in vs native 8-bit:' % pel, stats(mx, m8))
    for k in (0, 3, 4):
        a = core.mv.Mask(src8, vecs(src8), kind=k, ml=10)
        b = core.mv.Mask(src8, vecs(src10x), kind=k, ml=10)
        print('  pel=%d vectors, kind %d mask from 10-bit vectors vs 8-bit vectors:' % (pel, k), stats(b, a))

# --- B ---------------------------------------------------------------------
for it in (2, 3):
    for preset in ('Slow', 'Medium', 'Placebo'):
        kw = dict(Preset=preset, InputType=it, TFF=True)
        t = time.time()
        o8 = haf.QTGMC(src8, **kw)
        twice = stats(haf.QTGMC(src8, **kw), o8)
        CAPTURED.clear()
        helper8 = stats(qtgmc(src8, **kw), o8)
        m8 = CAPTURED[-1]
        ox = qtgmc(src10x, **kw)
        mx = CAPTURED[-1]
        orr = qtgmc(src10r, **kw)
        mr = CAPTURED[-1]
        off = dict(kw, ProgSADMask=0.0)
        c8 = haf.QTGMC(src8, **off)
        print('B IT=%d %-7s 8-bit: helper vs plain %s, plain twice %s' % (it, preset, helper8, twice))
        print('  mask inside QTGMC: exact-10 vs 8 %s, real-10 vs 8 %s' % (stats(mx, m8), stats(mr, m8)))
        print('  output: exact-10 vs 8 %s (Mask off: %s) | real-10 vs 8 %s (Mask off: %s)' % (
            stats(ox, o8), stats(haf.QTGMC(src10x, **off), c8),
            stats(orr, o8), stats(haf.QTGMC(src10r, **off), c8)))
        print('  Mask on vs off at 8 bits: %s | %.0f s' % (stats(c8, o8), time.time() - t))

# --- C ---------------------------------------------------------------------
for fmt in (vs.YUV420P10, vs.YUV420P16, vs.YUV444P12):
    c = core.resize.Point(src10r, format=fmt)
    try:
        qtgmc(c, Preset='Slow', InputType=2, TFF=True).get_frame(10)
        print('C', c.format.name, 'runs')
    except vs.Error as e:
        print('C', c.format.name, 'ERROR', str(e)[:100])
    try:
        haf.QTGMC(c, Preset='Slow', InputType=2, TFF=True).get_frame(10)
        print('  plain havsfunc runs too')
    except vs.Error as e:
        print('  plain havsfunc:', str(e)[:60])
hp = core.resize.Point(qtgmc(core.resize.Point(src8, format=vs.YUV422P16), Preset='Slow', InputType=2, TFF=True),
                       format=vs.YUV422P8, dither_type='error_diffusion')
print('C High Precision (8 -> 16 -> 8, dithered) vs 8-bit:', stats(hp, haf.QTGMC(src8, Preset='Slow', InputType=2, TFF=True)))
