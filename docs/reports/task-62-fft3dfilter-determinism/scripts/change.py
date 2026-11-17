"""How much the patch changes what users get: each pass that reaches
FFT3DFilter, through the unpatched build (as shipped up to deps 1.17) and the
patched one (build.sh), on the fixture at 720x480 4:2:0 8-bit, 10 frames.
The unpatched output itself varies run to run, so it is run 3 times and each
run compared with the patched result. Reported per plane in 8-bit levels:
mean |diff| over the picture, over the left 16 luma (8 chroma) columns, over
the rest, and the max.

  run.sh <deps> change.py <build.sh output dir>
"""
import json, sys
import vapoursynth as vs
from common import clip
import temporaldegrain2 as td
import havsfunc as haf
core = vs.core
B = sys.argv[1]
EXT = '.dylib' if sys.platform == 'darwin' else '.so'
core.std.LoadPlugin(B + '/orig/libfft3d_orig' + EXT)
core.std.LoadPlugin(B + '/fixed/libfft3d_fixed' + EXT)
core.num_threads = 8


class Proxy:
    def __init__(self, ns): self._ns = ns
    def __getattr__(self, k):
        return getattr(core, self._ns) if k == 'fft3dfilter' else getattr(core, k)


def with_ns(ns, fn):
    td.core = Proxy(ns); haf.core = Proxy(ns)
    try: return fn()
    finally: td.core = core; haf.core = core


c = clip('420', 8, 0, 720, 480, frames=10)
ci = clip('420', 8, 1, 720, 480, frames=10)
PASSES = {
    'Noise Reduction FFT3DFilter (sigma 2, bt 3)': lambda: core.fft3dfilter.FFT3DFilter(c, sigma=2.0, bt=3),
    'TemporalDegrain2 defaults (postFFT 0)': lambda: td.TemporalDegrain2(c),
    'TemporalDegrain2 postFFT 1': lambda: td.TemporalDegrain2(c, degrainTR=1, grainLevel=2, postFFT=1, postSigma=1.0),
    "QTGMC Fast, Denoiser='fft3dfilter', NoiseTR 1": lambda: haf.QTGMC(ci, Preset='Fast', TFF=True, NoiseProcess=1, Denoiser='fft3dfilter', NoiseTR=1, EZDenoise=2.0),
}


def stats(a, b):
    out = []
    for p in range(3):
        edge = 16 if p == 0 else 8
        tot = n = te = ne = mx = 0
        for fa, fb in zip(a.frames(), b.frames()):
            A, Bv = fa[p].tolist(), fb[p].tolist()
            for ra, rb in zip(A, Bv):
                for x, (u, v) in enumerate(zip(ra, rb)):
                    d = abs(u - v)
                    if x < edge: te += d; ne += 1
                    else: tot += d; n += 1
                    if d > mx: mx = d
        out.append({'mean': round((tot + te) / (n + ne), 4), 'left': round(te / ne, 4), 'rest': round(tot / n, 4), 'max': mx})
    return out


res = {}
for name, fn in PASSES.items():
    fixed = with_ns('fft3dfixed', fn)
    runs = [stats(with_ns('fft3dorig', fn), fixed) for _ in range(3)]
    res[name] = runs
    for i, r in enumerate(runs):
        print(name, 'run', i + 1, ' | '.join('%s mean %.4f left %.4f rest %.4f max %d' % (pl, s['mean'], s['left'], s['rest'], s['max'])
                                           for pl, s in zip('YUV', r)), flush=True)
print(json.dumps(res))
