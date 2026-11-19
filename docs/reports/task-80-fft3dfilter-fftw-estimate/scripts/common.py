"""Shared by this report's scripts: the pictures and the FFT3DFilter calls
VapourBox makes, each runnable at measure 0, 1 or the plugin's default.

Run every script with a deps bundle's Python and environment (run.sh on
macOS/Linux, run.ps1 on Windows). SCRATCH (environment) is where decoded
pictures go; VAPOURBOX_FFMPEG names the bundle's ffmpeg.
"""
import ctypes
import hashlib
import os
import random
import subprocess
import sys
import tempfile

import vapoursynth as vs

core = vs.core
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..'))
FIXTURE = os.path.join(REPO, 'Tests', 'TestResources', 'interlaced_test.avi')
SCRATCH = os.environ.get('SCRATCH') or tempfile.mkdtemp()
FFMPEG = os.environ.get('VAPOURBOX_FFMPEG', 'ffmpeg')


def synthetic(w=352, h=288, frames=12, bits=8):
    """The push gate's picture (vapoursynth_integration_test.dart): seeded
    noise, a new pattern every frame, 60% box-blurred."""
    blank = core.std.BlankClip(format=vs.YUV420P8, width=w, height=h, length=frames)

    def fill(n, f):
        out = f.copy()
        rnd = random.Random(1000 + n)
        for p in range(3):
            pw, ph = out.width >> (1 if p else 0), out.height >> (1 if p else 0)
            base = ctypes.cast(out.get_write_ptr(p), ctypes.c_void_p).value
            stride = out.get_stride(p)
            for y in range(ph):
                ctypes.memmove(base + y * stride, rnd.randbytes(pw), pw)
        return out

    noise = core.std.ModifyFrame(blank, blank, fill)
    c = core.std.Merge(noise, core.std.BoxBlur(noise, hradius=3, vradius=3), 0.6)
    return c if bits == 8 else core.resize.Point(c, format=vs.YUV420P16)


def fixture(w, h, frames=20, bits=8):
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


class _MeasureCore:
    """havsfunc's `core`, with `measure` added to every FFT3DFilter call:
    havsfunc passes none, so this is how its QTGMC call is run at 0 or 1."""

    def __init__(self, real, measure):
        self._real, self._measure = real, measure

    def __getattr__(self, name):
        attr = getattr(self._real, name)
        if name != 'fft3dfilter' or self._measure is None:
            return attr
        m = self._measure

        class _NS:
            def FFT3DFilter(self, *a, **kw):
                kw.setdefault('measure', m)
                return attr.FFT3DFilter(*a, **kw)
        return _NS()


def fft3d(c, measure, **kw):
    if measure is not None:
        kw['measure'] = measure
    return core.fft3dfilter.FFT3DFilter(c, **kw)


def qtgmc(c, measure):
    import havsfunc as haf
    real = haf.core
    haf.core = _MeasureCore(real, measure)
    try:
        return haf.QTGMC(c, Preset='Fast', TFF=True, NoiseProcess=1,
                         Denoiser='fft3dfilter', NoiseTR=1)
    finally:
        haf.core = real


# The calls VapourBox makes (task #62's report, section 5), by argument class.
CASES = {
    # TemporalDegrain2's spatial pass at its defaults: a sigma pattern, bt 3, 32 px.
    'td2_spat': lambda c, m: fft3d(c, m, planes=[0, 1, 2], sigma=16, sigma2=10, sigma3=6,
                                   sigma4=4, bt=3, bw=32, bh=32, ow=8, oh=8),
    # TemporalDegrain2's post pass (postFFT 1): one sigma, bt 3, 48 px.
    'td2_post': lambda c, m: fft3d(c, m, planes=[0, 1, 2], sigma=1.0, bt=3, bw=48, bh=48),
    # Noise Reduction's FFT3DFilter method at its default bt 3, and at bt 5.
    'nr_bt3': lambda c, m: fft3d(c, m, sigma=2.0, bt=3),
    'nr_bt5': lambda c, m: fft3d(c, m, sigma=4.0, bt=5),
    'bt1': lambda c, m: fft3d(c, m, sigma=16, bt=1),
    # havsfunc's QTGMC with the fft3dfilter denoiser (FFT3DFilter at bt 3 inside).
    'qtgmc': qtgmc,
}


def parse_measure(s):
    return None if s in ('default', 'none', '') else int(s)


def digest(c, prefetch=16):
    m = hashlib.md5()
    for f in c.frames(prefetch=prefetch):
        for p in range(f.format.num_planes):
            m.update(bytes(f[p]))
    return m.hexdigest()
