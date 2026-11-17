"""One hash per process: does FFT3DFilter agree across processes?
argv: width height measure"""
import hashlib, sys
import vapoursynth as vs
from common import clip
core = vs.core
w, h, measure = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
c = clip('420', 8, 0, w, h, frames=10)
out = {}
for k, kw in {'bt3': dict(sigma=2.0, bt=3), 'td2_spat': dict(planes=[0,1,2], sigma=16, sigma2=10, sigma3=6, sigma4=4, bt=3, bw=32, bh=32, ow=8, oh=8), 'td2_post': dict(planes=[0,1,2], sigma=1.0, bt=3, bw=48, bh=48)}.items():
    m = hashlib.md5()
    for f in core.fft3dfilter.FFT3DFilter(c, measure=measure, **kw).frames():
        for p in range(3): m.update(bytes(f[p]))
    out[k] = m.hexdigest()[:8]
print(out)
