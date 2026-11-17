"""Shared by this report's scripts: the repo, the probe's call list, and a
real picture (Tests/TestResources/interlaced_test.avi) at any size and format.

Run every script with the deps bundle's Python and environment (reproduce.sh).
SCRATCH (environment) is where decoded pictures go.
"""
import ctypes
import importlib.util
import os
import subprocess
import sys
import tempfile

import vapoursynth as vs

core = vs.core
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..'))
TEMPLATES = os.path.join(REPO, 'worker', 'templates')
FIXTURE = os.path.join(REPO, 'Tests', 'TestResources', 'interlaced_test.avi')
SCRATCH = os.environ.get('SCRATCH') or tempfile.mkdtemp()
FFMPEG = os.environ.get('VAPOURBOX_FFMPEG', 'ffmpeg')
SS = {'420': (1, 1), '422': (1, 0), '444': (0, 0)}

sys.path.insert(0, TEMPLATES)


def probe_calls():
    """The probe's call list (Scripts/probe-plugin-formats.py): each plugin
    call with the template's arguments."""
    path = os.path.join(REPO, 'Scripts', 'probe-plugin-formats.py')
    spec = importlib.util.spec_from_file_location('probe', path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod._calls()


_raw = {}


def picture(w, h, frames=10, loop=0):
    """The fixture scaled to w x h as 16-bit 4:4:4, [frames] long."""
    key = (w, h, frames)
    if key not in _raw:
        path = os.path.join(SCRATCH, 'src_%dx%d_%d.yuv' % key)
        if not os.path.exists(path):
            subprocess.run([FFMPEG, '-hide_banner', '-loglevel', 'error', '-y',
                            '-stream_loop', str(loop), '-i', FIXTURE, '-frames:v', str(frames),
                            '-vf', 'scale=%d:%d:flags=bicubic' % (w, h), '-pix_fmt', 'yuv444p16le',
                            '-f', 'rawvideo', path], check=True)
        blank = core.std.BlankClip(width=w, height=h, format=vs.YUV444P16, length=frames,
                                   fpsnum=30000, fpsden=1001)
        size = w * h * 2 * 3

        def fill(n, f, path=path):
            o = f.copy()
            with open(path, 'rb') as fh:
                fh.seek(n * size)
                data = fh.read(size)
            off = 0
            for p in range(3):
                base = ctypes.cast(o.get_write_ptr(p), ctypes.c_void_p).value
                st = o.get_stride(p)
                for y in range(h):
                    ctypes.memmove(base + y * st, data[off:off + w * 2], w * 2)
                    off += w * 2
            return o
        _raw[key] = core.std.ModifyFrame(blank, blank, fill)
    return _raw[key]


def clip(ss, bits, field, w, h, frames=10, loop=0):
    """The probe's cell: the picture at <ss>p<bits>, _FieldBased=field."""
    sw, sh = SS[ss]
    fmt = core.query_video_format(vs.YUV, vs.INTEGER, bits, sw, sh)
    c = core.resize.Bicubic(picture(w, h, frames, loop), format=fmt.id, dither_type='none')
    c = core.std.SetFrameProps(c, _Matrix=6, _Primaries=6, _Transfer=6, _Range=0, _ChromaLocation=0)
    return core.std.SetFieldBased(c, field)


def first_line(e):
    return ((str(e).strip().splitlines() or [type(e).__name__])[0])[:160]
