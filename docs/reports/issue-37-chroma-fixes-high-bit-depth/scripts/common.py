"""Shared helpers: the fixtures, the four filters at the templates' defaults,
and each depth guard, old and new, exactly as the templates run it.

The capture loader, promote(), to(), count() and mask8() are task #34's
(docs/reports/issue-34-descratch-high-bit-depth/scripts/common.py), copied so
this report stands alone. No source plugin and no numpy: raw planar files are
read with ctypes."""
import ctypes
import vapoursynth as vs
import havsfunc as haf

core = vs.core
W, H, N = 720, 576, 12


def load8(path):
    """A raw yuv422p file (the capture, decoded by ffmpeg) as a clip."""
    data = open(path, 'rb').read()
    blank = core.std.BlankClip(width=W, height=H, format=vs.YUV422P8, length=N)
    sizes = [(W, H), (W // 2, H), (W // 2, H)]
    fsize = sum(w * h for w, h in sizes)

    def fill(n, f):
        o = f.copy()
        off = n * fsize
        for p, (w, h) in enumerate(sizes):
            base = ctypes.cast(o.get_write_ptr(p), ctypes.c_void_p).value
            st = o.get_stride(p)
            for y in range(h):
                ctypes.memmove(base + y * st, data[off + y * w: off + (y + 1) * w], w)
            off += w * h
        return o
    return core.std.ModifyFrame(blank, blank, fill)


def _expr(clips, e, **kw):
    """akarin.Expr: the fixtures use its X/Y/N operands."""
    return core.akarin.Expr(clips, e, **kw)


def promote(c8):
    """The 8-bit picture at 16-bit with genuine sub-8-bit content: a smooth
    ripple of +-1.5 10-bit levels on luma and chroma. A deep file made by
    converting an 8-bit master has zero low bits, and every old guard was
    already bit-exact on it."""
    c = core.resize.Point(c8, format=vs.YUV422P16)
    return _expr(c, ['x X 0.13 * Y 0.07 * + sin 96 * + 0 max 65535 min',
                     'x X 0.21 * Y 0.05 * - sin 96 * + 0 max 65535 min'])


def static(c8):
    """The capture's first frame, held: the clean reference for artefacts()."""
    return core.std.Loop(core.std.Trim(c8, 0, 0), N)


def artefacts(c8):
    """static() with dot crawl and rainbow injected at 8-bit: a luma checker of
    +-4 levels and a chroma pattern of +-8 alternating per column, both
    flipping every frame (the heavy test's _crawlFixture, on the capture)."""
    return _expr(static(c8), ['x X Y + N + 2 % 2 * 1 - 4 * +',
                              'x X N + 2 % 2 * 1 - 8 * +',
                              'x X N + 2 % 2 * 1 - -8 * +'])


def gradient():
    """A shallow horizontal luma ramp, 64 to 80 in 8-bit levels across the
    frame, flat chroma, at 16-bit: where quantisation to 8 or 10 bits shows as
    bands. Luma is a plane Bifrost and LUTDeRainbow never change."""
    b = core.std.BlankClip(width=W, height=H, format=vs.YUV422P16, length=N,
                           color=[64 << 8, 32768, 32768])
    return _expr(b, ['X {} / 16 * 256 * 16384 +'.format(W - 1), 'x'])


def to(c, fmt, rng):
    """At [fmt] in range [rng] ('limited' or 'full'), field-flagged TFF as the
    templates mark an interlaced source. _Range follows H.273's
    video_full_range_flag: 0 is limited, 1 is full."""
    c = core.resize.Point(c, format=fmt)
    c = core.std.SetFrameProps(c, _Range=1 if rng == 'full' else 0)
    return core.std.SetFieldBased(c, 2)


# The filters at the templates' defaults, and the depth each works at.
FILTERS = {
    'DeDot': (8, lambda c: core.dedot.Dedot(c, luma_2d=20, luma_t=20, chroma_t1=15, chroma_t2=5)),
    'Bifrost': (8, lambda c: core.bifrost.Bifrost(c, luma_thresh=10.0, variation=5, interlaced=True)),
    'LUTDeCrawl': (10, lambda c: haf.LUTDeCrawl(c)),
    'LUTDeRainbow': (10, lambda c: haf.LUTDeRainbow(c)),
}


def down(c, bits):
    """The guards' down-conversion (zimg, no dither)."""
    return core.resize.Bilinear(c, format=c.format.replace(bits_per_sample=bits, sample_type=vs.INTEGER).id)


def old_block(name, c):
    """Before task #37: the whole low-depth result up-converted, dithered.
    DeDot used Bicubic both ways, the others Bilinear (the same at equal size)."""
    bits, filt = FILTERS[name]
    kernel = core.resize.Bicubic if name == 'DeDot' else core.resize.Bilinear
    lo = kernel(c, format=c.format.replace(bits_per_sample=bits, sample_type=vs.INTEGER).id)
    return kernel(filt(lo), format=c.format.id, dither_type='error_diffusion')


def new_block(name, c):
    """Task #37, the templates' _low_depth_change: src + up(filt(low)) - up(low)."""
    bits, filt = FILTERS[name]
    lo = down(c, bits)
    up = lambda x: core.resize.Point(x, format=c.format.id)
    return _expr([c, up(filt(lo)), up(lo)], 'x y + z -')


def planes(c):
    return [(c.width >> (c.format.subsampling_w if p else 0)) *
            (c.height >> (c.format.subsampling_h if p else 0)) * c.num_frames for p in range(3)]


def count(mask, plane=0):
    """Samples of [plane] where an 8-bit 0/255 mask is set, over all frames."""
    st = core.std.PlaneStats(mask, plane=plane)
    w = mask.width >> (mask.format.subsampling_w if plane else 0)
    h = mask.height >> (mask.format.subsampling_h if plane else 0)
    return round(sum(st.get_frame(i).props['PlaneStatsAverage'] for i in range(mask.num_frames)) * w * h)


def mask8(clips, e):
    """An 8-bit 0/255 mask of the same layout from an expression over clips."""
    return _expr(clips, e, format=clips[0].format.replace(bits_per_sample=8).id)
