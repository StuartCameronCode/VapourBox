# One MVTools call (or QTGMC) on a synthetic clip, for valgrind (task #66).
# vspipe -a call=<name> -a size=WxH -a fmt=<vs format name> bare.vpy -
#   call: qtgmc_draft | degrain_qtgmc | compensate_qtgmc | degrain | compensate
import vapoursynth as vs
core = vs.core

call = globals().get('call', b'qtgmc_draft')
size = globals().get('size', b'98x96')
fmt = globals().get('fmt', b'YUV420P12')
call, size, fmt = (x.decode() if isinstance(x, bytes) else x for x in (call, size, fmt))
w, h = map(int, size.split('x'))

c = core.std.BlankClip(width=w, height=h, format=getattr(vs, fmt), length=10)
peak = (1 << c.format.bits_per_sample) - 1
# A moving pattern with texture, so the vectors are not all zero. Pure
# Python: std.Expr has no X/Y, and akarin is not in every bundle.
import math


def _fill(n, f):
    fo = f.copy()
    for p in range(fo.format.num_planes):
        m = fo[p]
        ph, pw = m.shape
        for y in range(ph):
            for x in range(pw):
                v = (math.sin((x + 3 * n) / 5) + math.cos(y / 7)) * peak / 5 + peak / 2
                m[y, x] = int(v + ((x * y + n) % 13) * peak / 64)
    return fo


c = core.std.ModifyFrame(c, c, _fill)
c = core.std.SetFieldBased(c, 0)


def vectors(clip):
    srch = core.mv.Super(clip, pel=1, hpad=8, vpad=8)
    a = dict(blksize=32, overlap=8, search=0, searchparam=1, pelsearch=1, truemotion=False,
             _lambda=None)
    a = {k: v for k, v in a.items() if v is not None and not k.startswith('_')}
    return srch, core.mv.Analyse(srch, isb=True, delta=1, **a), core.mv.Analyse(srch, isb=False, delta=1, **a)


if call == 'qtgmc_draft':
    import havsfunc as haf
    out = haf.QTGMC(c, Preset='Draft', TFF=True)
elif call == 'degrain_qtgmc':
    srch, bv, fv = vectors(c)
    sup = core.mv.Super(c, pel=1, levels=1, hpad=8, vpad=8)
    out = core.mv.Degrain1(c, sup, bv, fv, thsad=640)
elif call == 'compensate_qtgmc':
    srch, bv, fv = vectors(c)
    sup = core.mv.Super(c, pel=1, levels=1, hpad=8, vpad=8)
    out = core.mv.Compensate(c, sup, bv)
elif call == 'degrain':
    sup = core.mv.Super(c, pel=1)
    out = core.mv.Degrain1(c, sup, core.mv.Analyse(sup, isb=True, blksize=32, overlap=8),
                           core.mv.Analyse(sup, isb=False, blksize=32, overlap=8))
elif call == 'compensate':
    sup = core.mv.Super(c, pel=1)
    out = core.mv.Compensate(c, sup, core.mv.Analyse(sup, isb=True, blksize=32, overlap=8))
else:
    raise vs.Error('bare.vpy: unknown call ' + call)

out = core.std.Trim(out, 4, 4)
out.set_output()
