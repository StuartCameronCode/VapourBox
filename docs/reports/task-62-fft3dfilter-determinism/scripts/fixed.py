import hashlib, json, sys, subprocess
import vapoursynth as vs
from common import clip
core = vs.core
B = sys.argv[1]  # build.sh's output directory
EXT = '.dylib' if sys.platform == 'darwin' else '.so'
core.std.LoadPlugin(B + '/orig/libfft3d_orig' + EXT)
core.std.LoadPlugin(B + '/fixed/libfft3d_fixed' + EXT)
core.num_threads = 8
mode = sys.argv[2]

def digest(c):
    m = hashlib.md5()
    for f in c.frames(prefetch=16):
        for p in range(f.format.num_planes): m.update(bytes(f[p]))
    return m.hexdigest()

def fns():
    return {'bundled': core.fft3dfilter.FFT3DFilter, 'orig_build': core.fft3dorig.FFT3DFilter, 'fixed_build': core.fft3dfixed.FFT3DFilter}

KW = {'td2_spat': dict(planes=[0,1,2], sigma=16, sigma2=10, sigma3=6, sigma4=4, bt=3, bw=32, bh=32, ow=8, oh=8),
      'td2_post': dict(planes=[0,1,2], sigma=1.0, bt=3, bw=48, bh=48),
      'default_bt1': dict(sigma=16, bt=1),
      'sharpen': dict(bt=-1, sharpen=1),
      'kalman_bt0': dict(sigma=4, bt=0),
      'measure0': dict(sigma=16, bt=1, measure=0)}

if mode == 'repeat':
    out = {}
    for bits in (8, 16):
        for w, h in ((720, 480), (720, 486)):
            c = clip('420', bits, 0, w, h, frames=10)
            for kname, kw in KW.items():
                for fname, fn in fns().items():
                    hs = {digest(fn(c, **kw)) for _ in range(5)}
                    out['%d-bit %dx%d %s %s' % (bits, w, h, kname, fname)] = len(hs)
                    print(bits, w, h, kname, fname, len(hs), flush=True)
    print(json.dumps(out))
elif mode == 'hash':
    # one hash per process: cross-process determinism (FFTW_MEASURE plans)
    c = clip('420', int(sys.argv[3]), 0, 720, 480, frames=10)
    print(json.dumps({k: digest(core.fft3dfixed.FFT3DFilter(c, **kw)) for k, kw in KW.items() if k != 'kalman_bt0'}))
