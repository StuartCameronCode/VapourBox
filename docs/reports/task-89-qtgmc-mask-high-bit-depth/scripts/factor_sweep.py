"""Task #89: the ml scaling factor. The helper multiplies ml by 2^(bits - 8)
for kind 1 (MVTools shifts each SAD by bits - 8, read from the clip). This
runs QTGMC InputType 2 at Slow with every other factor in the stand-in and
compares the mask inside QTGMC (and the output) with the 8-bit job's: the
difference should be smallest at x4 for 10 bits and x256 for 16 bits.
Means / maxima in 8-bit levels.
"""
import vapoursynth as vs
import havsfunc as haf

from common import core, sources, stats
import plugin_formats as pf

src10r, src8, src10x = sources()
FACTOR = [None]
CAPTURED = []


def stand_in(clip, vectors, ml=100.0, kind=0, **kw):
    # The shipped helper, with the kind-1 factor replaced by FACTOR.
    fmt = clip.format
    if fmt.bits_per_sample <= 8:
        m = core.mv.Mask(clip, vectors, ml=ml, kind=kind, **kw)
    else:
        stand = core.std.BlankClip(clip, format=fmt.replace(bits_per_sample=8).id, keep=True)
        if kind == 1:
            ml = ml * FACTOR[0]
        m = core.mv.Mask(stand, vectors, ml=ml, kind=kind, **kw)
        m = core.std.Expr(m, 'x %d * 255 /' % ((1 << fmt.bits_per_sample) - 1),
                          format=m.format.replace(bits_per_sample=fmt.bits_per_sample).id)
    CAPTURED.append(m)
    return m


pf.mvtools_mask_any_depth = stand_in
kw = dict(Preset='Slow', InputType=2, TFF=True)


def qtgmc(c):
    return pf.havsfunc_mask_any_depth(haf, lambda x: haf.QTGMC(x, **kw))(c)


o8 = qtgmc(src8)
m8 = CAPTURED[-1]
src16x = core.resize.Point(src8, format=vs.YUV422P16)
for name, src, factors in (('10-bit x4 picture', src10x, (1, 2, 3, 4, 5, 8, 16)),
                           ('real 10-bit', src10r, (2, 3, 4, 5, 8)),
                           ('16-bit x256 picture', src16x, (64, 128, 192, 256, 320, 512, 1024))):
    for f in factors:
        FACTOR[0] = f
        o = qtgmc(src)
        print('%-20s factor %5d: mask %s, output %s' % (name, f, stats(CAPTURED[-1], m8), stats(o, o8)))
