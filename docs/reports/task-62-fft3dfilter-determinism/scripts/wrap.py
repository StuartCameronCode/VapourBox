import hashlib, json, sys, time
import vapoursynth as vs
from common import clip
core = vs.core
B = sys.argv[1]  # build.sh's output directory
EXT = '.dylib' if sys.platform == 'darwin' else '.so'
core.std.LoadPlugin(B + '/fixed/libfft3d_fixed' + EXT); core.std.LoadPlugin(B + '/orig/libfft3d_orig' + EXT)
core.num_threads = 8

def reflect_left(c, pl, pc):
    """Each plane padded on the left by its reflection (edge sample not repeated)."""
    if c.format.color_family == vs.GRAY:
        planes = [c]
    else:
        planes = [core.std.ShufflePlanes(c, p, vs.GRAY) for p in range(3)]
    out = []
    for i, p in enumerate(planes):
        P = pl if i == 0 else pc
        strip = core.std.FlipHorizontal(core.std.Crop(p, left=1, right=p.width - 1 - P))
        out.append(core.std.StackHorizontal([strip, p]))
    if c.format.color_family == vs.GRAY:
        return out[0]
    return core.std.ShufflePlanes(out, [0, 0, 0], vs.YUV)

def fft3d(fn, c, **kw):
    bw = kw.get('bw', 48); ow = kw.get('ow', -1)
    if ow < 0: ow = bw // 3
    mirw = bw - ow
    ssw = c.format.subsampling_w
    pc = mirw; pl = mirw << ssw
    bt = kw.get('bt', 3)
    sig = kw.get('sigma', 2.0)
    pattern = any(k in kw and kw[k] != sig for k in ('sigma2', 'sigma3', 'sigma4')) or kw.get('pfactor', 0) != 0
    padded = reflect_left(c, pl, pc)
    def run(**k):
        o = fn(padded, **k)
        return core.std.Crop(o, left=pl)
    out = run(**kw)
    if bt > 1 and not pattern:
        a, b = bt // 2, (bt - 1) // 2
        k1 = dict(kw); k1['bt'] = 1
        edge = run(**k1)
        n = c.num_frames
        out = edge[:a] + out[a:n - b] + edge[n - b:]
    return out

def digest(c):
    m = hashlib.md5()
    for f in c.frames(prefetch=16):
        for p in range(f.format.num_planes): m.update(bytes(f[p]))
    return m.hexdigest()

KW = {'td2_spat': dict(planes=[0,1,2], sigma=16, sigma2=10, sigma3=6, sigma4=4, bt=3, bw=32, bh=32, ow=8, oh=8),
      'td2_post': dict(planes=[0,1,2], sigma=1.0, bt=3, bw=48, bh=48),
      'nr_default': dict(sigma=2.0, bt=3),
      'nr_bt5': dict(sigma=2.0, bt=5, sharpen=0.5),
      'bt1': dict(sigma=16, bt=1)}
out = {}
for ss in ('420', '422', '444'):
    for bits in (8, 10, 16):
        for w, h in ((720, 480), (96, 64)):
            c = clip(ss, bits, 0, w, h, frames=10)
            for k, kw in KW.items():
                ref = digest(core.fft3dfixed.FFT3DFilter(c, **kw))
                hs = {digest(fft3d(core.fft3dorig.FFT3DFilter, c, **kw)) for _ in range(3)}
                key = '%s p%d %dx%d %s' % (ss, bits, w, h, k)
                out[key] = {'distinct': len(hs), 'equals_fixed_plugin': hs == {ref}}
                print(key, out[key], flush=True)
print(json.dumps(out))
