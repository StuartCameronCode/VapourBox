# One MVTools call (or QTGMC) on a synthetic clip, for valgrind (task #66).
# vspipe -a call=<name> -a size=WxH -a fmt=<vs format name> bare.vpy -
#   call: qtgmc_draft | qtgmc_fast | qtgmc_slower | qtgmc_placebo | degrain_qtgmc |
#         compensate_qtgmc | degrain | compensate | degrain_merge | merge
# Task #70 added, all optional:
#   cpu=none|sse2|avx2|...  core.std.SetMaxCPU before the graph: 'none' runs
#                           VapourSynth's own kernels in C (plugins unaffected)
#   defined=1               the source writes its whole buffer, stride padding
#                           included, so its frames carry no undefined bytes
#   degrain_merge           degrain_qtgmc, then std.Merge(out, source, 0.25):
#                           QTGMC Draft's `binomial1` arrangement
#   merge                   std.Merge of the source with itself shifted a frame
#   leak                    degrain_qtgmc, then the bytes just past each chroma
#                           row's last sample (padding Degrain never writes)
#                           copied into that row's first sample: a deliberate
#                           padding read, the positive control for `verify`
import ctypes
import vapoursynth as vs
core = vs.core
cpu = globals().get('cpu', b'')
cpu = cpu.decode() if isinstance(cpu, bytes) else cpu
if cpu:
    core.std.SetMaxCPU(cpu)
defined = globals().get('defined', b'0') in (b'1', '1')

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
        if defined:
            ph = fo.height >> (fo.format.subsampling_h if p else 0)
            ctypes.memset(ctypes.cast(fo.get_write_ptr(p), ctypes.c_void_p).value, 0,
                          fo.get_stride(p) * ph)
        m = fo[p]
        ph, pw = m.shape
        for y in range(ph):
            for x in range(pw):
                v = (math.sin((x + 3 * n) / 5) + math.cos(y / 7)) * peak / 5 + peak / 2
                m[y, x] = min(peak, int(v + ((x * y + n) % 13) * peak / 64))
    return fo


c = core.std.ModifyFrame(c, c, _fill)
c = core.std.SetFieldBased(c, 0)


def vectors(clip):
    srch = core.mv.Super(clip, pel=1, hpad=8, vpad=8)
    a = dict(blksize=32, overlap=8, search=0, searchparam=1, pelsearch=1, truemotion=False,
             _lambda=None)
    a = {k: v for k, v in a.items() if v is not None and not k.startswith('_')}
    return srch, core.mv.Analyse(srch, isb=True, delta=1, **a), core.mv.Analyse(srch, isb=False, delta=1, **a)


if call.startswith('qtgmc_'):
    import havsfunc as haf
    preset = {'draft': 'Draft', 'fast': 'Fast', 'slower': 'Slower', 'placebo': 'Placebo'}[call[6:]]
    out = haf.QTGMC(c, Preset=preset, TFF=True)
elif call == 'degrain_qtgmc':
    srch, bv, fv = vectors(c)
    sup = core.mv.Super(c, pel=1, levels=1, hpad=8, vpad=8)
    out = core.mv.Degrain1(c, sup, bv, fv, thsad=640)
elif call == 'degrain_merge':
    srch, bv, fv = vectors(c)
    sup = core.mv.Super(c, pel=1, levels=1, hpad=8, vpad=8)
    out = core.std.Merge(core.mv.Degrain1(c, sup, bv, fv, thsad=640), c, weight=[0.25])
elif call == 'leak':
    srch, bv, fv = vectors(c)
    sup = core.mv.Super(c, pel=1, levels=1, hpad=8, vpad=8)
    deg = core.mv.Degrain1(c, sup, bv, fv, thsad=640)

    def _leak(n, f):
        fo = f.copy()
        bps = fo.format.bytes_per_sample
        for p in range(1, fo.format.num_planes):
            pw = fo.width >> fo.format.subsampling_w
            ph = fo.height >> fo.format.subsampling_h
            src = ctypes.cast(f.get_read_ptr(p), ctypes.c_void_p).value
            dst = ctypes.cast(fo.get_write_ptr(p), ctypes.c_void_p).value
            for y in range(ph):
                ctypes.memmove(dst + y * fo.get_stride(p), src + y * f.get_stride(p) + pw * bps, bps)
        return fo
    out = core.std.ModifyFrame(deg, deg, _leak)
elif call == 'merge':
    out = core.std.Merge(c, c[1:] + c[-1], weight=[0.25])
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
