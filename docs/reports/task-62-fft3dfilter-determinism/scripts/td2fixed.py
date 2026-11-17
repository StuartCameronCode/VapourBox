import hashlib, json, sys
import vapoursynth as vs
from common import clip
import temporaldegrain2 as td
import havsfunc as haf
core = vs.core
B = sys.argv[1]  # build.sh's output directory
EXT = '.dylib' if sys.platform == 'darwin' else '.so'
core.std.LoadPlugin(B + '/orig/libfft3d_orig' + EXT); core.std.LoadPlugin(B + '/fixed/libfft3d_fixed' + EXT)

class Proxy:
    def __init__(self, ns): self._ns = ns
    def __getattr__(self, k):
        if k == 'fft3dfilter': return getattr(core, self._ns)
        return getattr(core, k)

def digest(c):
    m = hashlib.md5()
    for f in c.frames(prefetch=16):
        for p in range(f.format.num_planes): m.update(bytes(f[p]))
    return m.hexdigest()

def with_ns(ns, fn):
    td.core = Proxy(ns); haf.core = Proxy(ns)
    try: return fn()
    finally: td.core = core; haf.core = core

out = {}
for threads in (8, 1):
    core.num_threads = threads
    for bits in (8, 16):
        for h in (480, 486):
            c = clip('420', bits, 0, 720, h, frames=10)
            ci = clip('420', bits, 1, 720, h, frames=10)
            for ns in ('fft3dorig', 'fft3dfixed'):
                for name, fn in (('td2_post1', lambda: td.TemporalDegrain2(c, degrainTR=1, grainLevel=2, postFFT=1, postSigma=1.0)),
                                 ('td2_default', lambda: td.TemporalDegrain2(c)),
                                 ('qtgmc_fft3d', lambda: haf.QTGMC(ci, Preset='Fast', TFF=True, NoiseProcess=1, Denoiser='fft3dfilter', NoiseTR=1, EZDenoise=2.0))):
                    if name.startswith('qtgmc') and h == 486: continue
                    hs = {digest(with_ns(ns, fn)) for _ in range(4)}
                    key = '%d threads %d-bit 720x%d %s %s' % (threads, bits, h, name, ns)
                    out[key] = len(hs); print(key, len(hs), flush=True)
print(json.dumps(out))
