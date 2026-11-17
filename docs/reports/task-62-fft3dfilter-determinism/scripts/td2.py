import hashlib, json, sys, time
import vapoursynth as vs
from common import clip
import temporaldegrain2 as td
from hybrid_mv import MV
core = vs.core
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 6

def digest(c):
    m = hashlib.md5()
    for f in c.frames(prefetch=16):
        for p in range(f.format.num_planes):
            m.update(bytes(f[p]))
    return m.hexdigest()

def src(w=720, h=480, bits=8, frames=10):
    return clip('420', bits, 0, w, h, frames=frames)

def graph(name, c):
    if name == 'full':      return td.TemporalDegrain2(c, degrainTR=1, grainLevel=2, postFFT=1, postSigma=1.0)
    if name == 'post0':     return td.TemporalDegrain2(c, degrainTR=1, grainLevel=2, postFFT=0)
    if name == 'post3':     return td.TemporalDegrain2(c, degrainTR=1, grainLevel=2, postFFT=3)
    if name == 'stage0':    return td.TemporalDegrain2(c, degrainTR=1, grainLevel=2, outputStage=0)
    if name == 'stage1':    return td.TemporalDegrain2(c, degrainTR=1, grainLevel=2, outputStage=1)
    if name == 'tr0_post1': return td.TemporalDegrain2(c, degrainTR=0, grainLevel=2, postFFT=1, postSigma=1.0)
    if name == 'fft3d_spat':
        return core.fft3dfilter.FFT3DFilter(c, planes=[0,1,2], sigma=16, sigma2=10, sigma3=6, sigma4=4, bt=3, bw=32, bh=32, ow=8, oh=8)
    if name == 'fft3d_bt1':
        return core.fft3dfilter.FFT3DFilter(c, planes=[0,1,2], sigma=16, bt=1, bw=32, bh=32, ow=8, oh=8)
    if name == 'fft3d_post':
        return core.fft3dfilter.FFT3DFilter(c, planes=[0,1,2], sigma=1.0, bt=3, bw=48, bh=48)
    if name == 'dfttest':
        return core.dfttest.DFTTest(c, sigma=4, tbsize=3, sbsize=12, sosize=9)
    if name == 'mvdegrain':
        sup = core.mv.Super(c, pel=4, sharp=2, hpad=8, vpad=8)
        v = MV.AnalyseMany(sup, radius=1, blksize=8, overlap=4, search=4, searchparam=2, pelsearch=4, truemotion=False, lambda_=100, pnew=25, global_=True, dct=0, chroma=True)
        s1 = core.mv.Super(c, pel=4, sharp=2, hpad=8, vpad=8, levels=1)
        return MV.Degrain(c, s1, *v, plane=4, thsad=448, limit=255, thscd1=192, thscd2=128)
    raise ValueError(name)

if sys.argv[1] == 'repeat':
    names = sys.argv[3].split(',')
    threads = [int(t) for t in sys.argv[4].split(',')] if len(sys.argv) > 4 else [8, 1]
    size = (720, 480)
    out = {}
    for name in names:
        for t in threads:
            core.num_threads = t
            t0 = time.time()
            hs = [digest(graph(name, src(*size))) for _ in range(RUNS)]
            out.setdefault(name, {})[t] = len(set(hs))
            print(name, t, len(set(hs)), round(time.time()-t0, 1), flush=True)
    print(json.dumps(out))
