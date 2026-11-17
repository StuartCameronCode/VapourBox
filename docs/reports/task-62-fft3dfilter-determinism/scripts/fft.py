import json, sys, hashlib
import vapoursynth as vs
from common import clip
core = vs.core
core.num_threads = int(sys.argv[2]) if len(sys.argv) > 2 else 8
mode = sys.argv[1]

def cmp(a, b):
    """per frame: [(max abs diff, fraction differing) per plane]"""
    d = core.std.Expr([a, b], 'x y - abs')
    ne = core.std.Expr([a, b], 'x y = 0 255 ?', format=a.format.replace(bits_per_sample=8).id) if a.format.bits_per_sample == 8 else None
    out = []
    planes = range(a.format.num_planes)
    ds = [core.std.PlaneStats(d, plane=p) for p in planes]
    ns = [core.std.PlaneStats(ne, plane=p) for p in planes] if ne else None
    for n in range(a.num_frames):
        row = []
        for p in planes:
            mx = ds[p].get_frame(n).props['PlaneStatsMax']
            fr = ns[p].get_frame(n).props['PlaneStatsAverage'] if ns else None
            row.append((mx, round(fr, 5) if fr is not None else None))
        out.append(row)
    return out

def src(w=720, h=480, bits=8, frames=10):
    return clip('420', bits, 0, w, h, frames=frames)

def worst(c, kw, n=4):
    ref = core.fft3dfilter.FFT3DFilter(c, **kw)
    mx, nd, frac = 0, 0, 0
    for _ in range(n - 1):
        r = cmp(ref, core.fft3dfilter.FFT3DFilter(c, **kw))
        m = max(x[0] for row in r for x in row)
        mx = max(mx, m)
        nd += m > 0
        frac = max(frac, max((x[1] or 0) for row in r for x in row))
    return mx, nd, n - 1, frac

if mode == 'detail':
    c = src()
    kw = dict(sigma=16, bt=1, bw=32, bh=32, ow=8, oh=8, planes=[0,1,2])
    r = cmp(core.fft3dfilter.FFT3DFilter(c, **kw), core.fft3dfilter.FFT3DFilter(c, **kw))
    for i, row in enumerate(r): print(i, row)
elif mode == 'variants':
    c = src()
    for name, kw in [('default', {}), ('bt1', dict(bt=1)), ('bt0_kalman', dict(bt=0)), ('bt-1_sharpen', dict(bt=-1, sharpen=1)),
                     ('sigma0', dict(sigma=0)), ('bt1_sigma16_bw32', dict(bt=1, sigma=16, bw=32, bh=32, ow=8, oh=8)),
                     ('ncpu1', dict(ncpu=1)), ('ncpu4', dict(ncpu=4)), ('post_bt3_bw48', dict(sigma=1, bt=3, bw=48, bh=48)),
                     ('y_only', dict(planes=[0]))]:
        print(name, 'max %s, differing runs %d of %d, max fraction of samples %s' % worst(c, kw), flush=True)
elif mode == 'blank':
    c = core.std.BlankClip(width=720, height=480, format=vs.YUV420P8, length=10, color=[100, 128, 128])
    print('blank', worst(c, dict(sigma=16, bt=1)))
elif mode == 'hash':
    c = src()
    m = hashlib.md5()
    for f in core.fft3dfilter.FFT3DFilter(c, sigma=16, bt=1).frames():
        for p in range(3): m.update(bytes(f[p]))
    print(m.hexdigest())
