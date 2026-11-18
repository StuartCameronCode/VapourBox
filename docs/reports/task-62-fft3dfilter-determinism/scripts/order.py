"""Frame k of FFT3DFilter: alone in a fresh graph, vs after other frames."""
import hashlib, sys
import vapoursynth as vs
from common import clip
core = vs.core
core.num_threads = int(sys.argv[1])
c = clip('420', 8, 0, 640, 480, frames=10)
def h(f):
    m = hashlib.md5()
    for p in range(3): m.update(bytes(f[p]))
    return m.hexdigest()[:8]
for name, kw in {'bt3': dict(sigma=2.0, bt=3), 'bt1': dict(sigma=2.0, bt=1)}.items():
    k = 5
    alone = {h(core.fft3dfilter.FFT3DFilter(c, **kw).get_frame(k)) for _ in range(4)}
    seq = set()
    for _ in range(4):
        n = core.fft3dfilter.FFT3DFilter(c, **kw)
        fr = list(n.frames())
        seq.add(h(fr[k]))
    after9 = set()
    for _ in range(4):
        n = core.fft3dfilter.FFT3DFilter(c, **kw)
        n.get_frame(9); n.get_frame(2)
        after9.add(h(n.get_frame(k)))
    print(name, 'alone', alone, 'sequential', seq, 'after 9,2', after9)
