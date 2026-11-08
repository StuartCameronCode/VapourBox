"""Probe helpers: load a source through ffmpeg into a VapourSynth clip, metrics."""
import ctypes
import math
import os
import subprocess
import time

import vapoursynth as vs

core = vs.core

FMTS = {
    'yuv420p': vs.YUV420P8, 'yuv422p': vs.YUV422P8, 'yuv444p': vs.YUV444P8,
    'yuv420p10le': vs.YUV420P10, 'yuv422p10le': vs.YUV422P10,
    'yuv420p12le': vs.YUV420P12, 'yuv420p16le': vs.YUV420P16,
    'yuv422p16le': vs.YUV422P16,
}


def load(path, pix_fmt='yuv420p', frames=10, start=0, vf=None):
    fmt = core.get_video_format(FMTS[pix_fmt])
    probe = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                            'stream=width,height', '-of', 'csv=p=0', path],
                           capture_output=True, text=True, check=True).stdout.strip().split(',')
    w, h = int(probe[0]), int(probe[1])
    args = ['ffmpeg', '-v', 'error', '-apply_cropping', 'codec', '-i', path]
    filt = f'select=gte(n\\,{start})'
    if vf:
        filt += ',' + vf
    args += ['-vf', filt, '-frames:v', str(frames), '-pix_fmt', pix_fmt, '-f', 'rawvideo', '-']
    data = subprocess.run(args, capture_output=True, check=True).stdout
    if vf and 'scale=' in vf:
        sc = vf.split('scale=')[1].split(',')[0].split(':')
        w, h = int(sc[0]), int(sc[1])
    bps = fmt.bytes_per_sample
    sizes = [w * h * bps] + [(w >> fmt.subsampling_w) * (h >> fmt.subsampling_h) * bps] * 2
    fsize = sum(sizes)
    n = len(data) // fsize
    blank = core.std.BlankClip(width=w, height=h, format=fmt.id, length=n, fpsnum=25, fpsden=1)

    def fill(n, f):
        fout = f.copy()
        off = n * fsize
        for p in range(3):
            pw = w >> (fmt.subsampling_w if p else 0)
            ph = h >> (fmt.subsampling_h if p else 0)
            row = pw * bps
            stride = fout.get_stride(p)
            ptr = fout.get_write_ptr(p)
            dst = ptr if isinstance(ptr, int) else ptr.value
            buf = (ctypes.c_char * sizes[p]).from_buffer_copy(data, off)
            for r in range(ph):
                ctypes.memmove(dst + r * stride, ctypes.addressof(buf) + r * row, row)
            off += sizes[p]
        return fout

    return core.std.ModifyFrame(blank, blank, fill)


def expr(clips, e, fmt=None):
    kw = {} if fmt is None else {'format': fmt}
    if hasattr(core, 'akarin'):
        return core.akarin.Expr(clips, e, **kw)
    return core.std.Expr(clips, e, **kw)


def _diff8(a, b, plane, op):
    a = core.std.ShufflePlanes(a, plane, vs.GRAY)
    b = core.std.ShufflePlanes(b, plane, vs.GRAY)
    sa = 1.0 / (1 << (a.format.bits_per_sample - 8))
    sb = 1.0 / (1 << (b.format.bits_per_sample - 8))
    return expr([a, b], f'x {sa} * y {sb} * - ' + op, vs.GRAYS)


def psnr(a, b, plane=0, frames=None):
    """Mean PSNR over frames, in 8-bit units (peak 255)."""
    st = core.std.PlaneStats(_diff8(a, b, plane, 'dup *'))
    n = st.num_frames if frames is None else min(frames, st.num_frames)
    vals = []
    for i in range(n):
        mse = st.get_frame(i).props['PlaneStatsAverage']
        vals.append(99.0 if mse <= 0 else 10 * math.log10(255 * 255 / mse))
    return sum(vals) / len(vals)


def mad8(a, b, plane=0, frames=None):
    """Mean absolute difference in 8-bit levels."""
    st = core.std.PlaneStats(_diff8(a, b, plane, 'abs'))
    n = st.num_frames if frames is None else min(frames, st.num_frames)
    return sum(st.get_frame(i).props['PlaneStatsAverage'] for i in range(n)) / n


def timed(clip, frames=None):
    n = clip.num_frames if frames is None else min(frames, clip.num_frames)
    t = time.time()
    for f in clip.frames(close=True):
        n -= 1
        if n <= 0:
            break
    return time.time() - t
