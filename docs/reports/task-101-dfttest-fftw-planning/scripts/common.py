"""Shared by this report's scripts: the pictures and the DFTTest calls
VapourBox makes (plus FFT3DFilter and DCTFilter, for the wisdom check and
for information).

Run every script with a deps bundle's Python and environment (run.sh on
macOS/Linux, run.ps1 on Windows). SCRATCH (environment) is where decoded
pictures go; VAPOURBOX_FFMPEG names the bundle's ffmpeg. Which DFTTest
build is measured is whichever the bundle holds: `plugin_name()` reports it
(task #98's marker, and task #101's when the ESTIMATE patch is in).
"""
import ctypes
import hashlib
import os
import subprocess
import sys
import tempfile

import vapoursynth as vs

core = vs.core
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..'))
FIXTURE = os.path.join(REPO, 'Tests', 'TestResources', 'interlaced_test.avi')
SCRATCH = os.environ.get('SCRATCH') or tempfile.mkdtemp()
os.makedirs(SCRATCH, exist_ok=True)
FFMPEG = os.environ.get('VAPOURBOX_FFMPEG', 'ffmpeg')
FRAMES = 12


def plugin_name():
    return core.dfttest.name


def grain(w=720, h=480, frames=FRAMES, bits=8):
    """Task #98's picture (same_output.vpy): flat grey with seeded grain,
    a new pattern every frame."""
    c = core.std.BlankClip(width=w, height=h, format=vs.YUV420P8, length=frames,
                           color=[100, 120, 140])
    c = core.grain.Add(c, var=60, uvar=20, seed=7, constant=False)
    return c if bits == 8 else core.resize.Point(c, format=vs.YUV420P16)


def fixture(w=720, h=480, frames=FRAMES, bits=8):
    """Real interlaced VHS picture (Tests/TestResources/interlaced_test.avi),
    scaled to w x h by ffmpeg, 4:2:0, at 8 or 16 bits (16 decoded by ffmpeg
    from the 8-bit source, so it has real sub-8-bit content from the scale)."""
    pix = 'yuv420p' if bits == 8 else 'yuv420p16le'
    path = os.path.join(SCRATCH, 'fix_%dx%d_%d_%d.yuv' % (w, h, frames, bits))
    if not os.path.exists(path):
        subprocess.run([FFMPEG, '-hide_banner', '-loglevel', 'error', '-y',
                        '-stream_loop', '-1', '-i', FIXTURE, '-frames:v', str(frames),
                        '-vf', 'scale=%d:%d:flags=bicubic:interl=1' % (w, h), '-pix_fmt', pix,
                        '-f', 'rawvideo', path], check=True)
    fmt = vs.YUV420P8 if bits == 8 else vs.YUV420P16
    bps = 1 if bits == 8 else 2
    blank = core.std.BlankClip(width=w, height=h, format=fmt, length=frames,
                               fpsnum=30000, fpsden=1001)
    size = w * h * bps * 3 // 2
    with open(path, 'rb') as fh:
        data = fh.read()

    def fill(n, f):
        o = f.copy()
        off = n * size
        for p in range(3):
            pw, ph = (w, h) if p == 0 else (w // 2, h // 2)
            base = ctypes.cast(o.get_write_ptr(p), ctypes.c_void_p).value
            st = o.get_stride(p)
            for y in range(ph):
                ctypes.memmove(base + y * st, data[off:off + pw * bps], pw * bps)
                off += pw * bps
        return o

    return core.std.ModifyFrame(blank, blank, fill)


def pictures():
    return {
        'grain': {8: grain(bits=8), 16: grain(bits=16)},
        'vhs': {8: fixture(bits=8), 16: fixture(bits=16)},
    }


def dft(c, **kw):
    return core.dfttest.DFTTest(c, **kw)


def qtgmc_dfttest(c):
    import havsfunc as haf
    return haf.QTGMC(c, Preset='Fast', TFF=True, NoiseProcess=1, Denoiser='dfttest',
                     NoiseTR=1)


def smdegrain_pf3(c):
    import havsfunc as haf
    return haf.SMDegrain(c, tr=2, prefilter=3)


def td2_post3(c):
    """The template's TemporalDegrain2 with its DFTTest post pass (postFFT 3);
    its spatial pass is FFT3DFilter (measure=0), so this is also the mixed
    graph a job builds."""
    sys.path.insert(0, os.path.join(REPO, 'worker', 'templates'))
    import temporaldegrain2 as td2m
    return td2m.TemporalDegrain2(c, postFFT=3)


# The DFTTest calls VapourBox makes, by plan shape.
CASES = {
    # Noise Reduction's DFTTest method at its defaults (sigma 8, tbsize 3,
    # sbsize 16) and a stronger setting.
    'nr_default': lambda c: dft(c, sigma=8.0, tbsize=3, sbsize=16),
    'nr_strong': lambda c: dft(c, sigma=16.0, tbsize=5, sbsize=16),
    # (DFTTest's own defaults are sigma 8, tbsize 3, sbsize 16: nr_default
    # is also task #98's `DFTTest(tbsize=3)`.)
    # Another 3D size: sbsize 12.
    'tb3_sb12': lambda c: dft(c, tbsize=3, sbsize=12, sosize=6),
    # 2D plans: havsfunc's prefilter call (tbsize 1, sigma 10, sbsize 16),
    # and sbsize 12.
    'tb1': lambda c: dft(c, tbsize=1, sigma=10.0),
    'tb1_sb12': lambda c: dft(c, tbsize=1, sbsize=12, sosize=6, sigma=10.0),
    # havsfunc's QTGMC with the dfttest denoiser (also the knlmeanscl fallback).
    'qtgmc_dfttest': qtgmc_dfttest,
    # SMDegrain's DFTTest prefilter.
    'smdegrain_pf3': smdegrain_pf3,
    # TemporalDegrain2 with postFFT 3.
    'td2_post3': td2_post3,
}
# Interlaced-only calls skip the grain picture (it has no fields).
INTERLACED_ONLY = {'qtgmc_dfttest'}
# Heavy whole-filter calls run at 8 bits only, to keep a process short.
EIGHT_BIT_ONLY = {'qtgmc_dfttest', 'smdegrain_pf3', 'td2_post3'}

# For information (not changed by this task): DCTFilter plans with
# FFTW_PATIENT too (task #96 kept it), and FFT3DFilter at measure=0.
INFO_CASES = {
    'dctfilter': lambda c: core.dctf.DCTFilter(c, factors=[1, 1, 1, 0.5, 0.5, 0, 0, 0]),
    'fft3d_td2_spat': lambda c: core.fft3dfilter.FFT3DFilter(
        c, planes=[0, 1, 2], sigma=16, sigma2=10, sigma3=6, sigma4=4, bt=3, bw=32, bh=32,
        ow=8, oh=8, measure=0),
    'fft3d_nr_bt3': lambda c: core.fft3dfilter.FFT3DFilter(c, sigma=2.0, bt=3, measure=0),
}


def keys(cases=None):
    """(key, case name, picture, depth) for every combination measured."""
    cases = CASES if cases is None else cases
    out = []
    for pname in ('grain', 'vhs'):
        for depth in (8, 16):
            for name in cases:
                if name in INTERLACED_ONLY and pname == 'grain':
                    continue
                if name in EIGHT_BIT_ONLY and depth != 8:
                    continue
                out.append(('%s %s %d' % (name, pname, depth), name, pname, depth))
    return out


def cached(c):
    """c rendered once and served from memory, so a timing measures the
    filter, not this script's Python source."""
    frames = [f.copy() for f in c.frames(prefetch=16)]
    return core.std.ModifyFrame(c, c, lambda n, f: frames[n])


def raw(c, prefetch=16):
    """Every plane of every frame, as bytes (for hashing or dumping)."""
    for f in c.frames(prefetch=prefetch):
        for p in range(f.format.num_planes):
            yield bytes(f[p])


def digest(c):
    m = hashlib.md5()
    for b in raw(c):
        m.update(b)
    return m.hexdigest()


def fftw_library():
    """The bundle's libfftw3f, the same image the plugins load (ctypes
    returns the already-loaded image for the same path)."""
    deps = os.environ.get('VAPOURBOX_DEPS')
    if sys.platform == 'darwin':
        path = os.path.join(deps, 'lib', 'libfftw3f.3.dylib')
    elif sys.platform == 'win32':
        # vs-plugins from deps 1.18.0-rc4 (task #90), vapoursynth\ before.
        path = next(p for p in (os.path.join(deps, 'vapoursynth', 'vs-plugins', 'libfftw3f-3.dll'),
                                os.path.join(deps, 'vapoursynth', 'libfftw3f-3.dll'))
                    if os.path.exists(p))
    else:
        path = os.path.join(deps, 'lib', 'libfftw3f.so.3')
    return ctypes.CDLL(path)
