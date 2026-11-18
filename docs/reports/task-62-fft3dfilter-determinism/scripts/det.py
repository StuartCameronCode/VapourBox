"""Distinct output hashes of FFT3DFilter and TemporalDegrain2 over fresh
graphs, with whichever fft3dfilter the bundle autoloads."""
import hashlib, json, sys
import vapoursynth as vs
from common import clip
core = vs.core
core.num_threads = int(sys.argv[1]) if len(sys.argv) > 1 else 8
RUNS = 5
print('plugin:', [p.plugin_path.rsplit('/', 3)[-3:] for p in core.plugins() if p.namespace == 'fft3dfilter'])

def digest(c):
    m = hashlib.md5()
    for f in c.frames(prefetch=16):
        for p in range(f.format.num_planes): m.update(bytes(f[p]))
    return m.hexdigest()

KW = {'td2_spat': dict(planes=[0,1,2], sigma=16, sigma2=10, sigma3=6, sigma4=4, bt=3, bw=32, bh=32, ow=8, oh=8),
      'td2_post': dict(planes=[0,1,2], sigma=1.0, bt=3, bw=48, bh=48),
      'nr_bt3': dict(sigma=2.0, bt=3),
      'nr_bt5': dict(sigma=4.0, bt=5),
      'default_bt1': dict(sigma=16, bt=1),
      'sharpen': dict(bt=-1, sharpen=1)}
out = {}
import temporaldegrain2 as td2
for bits in (8, 16):
    for w, h in ((720, 480), (720, 486)):
        c = clip('420', bits, 0, w, h, frames=10)
        for k, kw in KW.items():
            out['%d %dx%d fft3d %s' % (bits, w, h, k)] = len({digest(core.fft3dfilter.FFT3DFilter(c, **kw)) for _ in range(RUNS)})
        for pf in (0, 1):
            out['%d %dx%d td2 postFFT=%d' % (bits, w, h, pf)] = len({digest(td2.TemporalDegrain2(c, degrainTR=1, grainLevel=2, postFFT=pf, postSigma=1.0)) for _ in range(RUNS)})
for k, v in out.items(): print(v, k)
print('MAX', max(out.values()))
