"""Shared helpers: the fixtures and the DeScratch block, old and new, exactly as
the templates run it (8-bit down-conversion, 4:2:0 luma on a 4:2:2 carrier).

No source plugin and no numpy: raw planar files are read with ctypes."""
import ctypes
import vapoursynth as vs

core = vs.core
W, H, N = 720, 576, 12
# Three dark vertical scratches, as #29's report and the heavy test draw them.
SCRATCHES = [(150, 2, 0.60), (361, 1, 0.50), (560, 3, 0.65)]  # x, width, gain


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
    """akarin.Expr: the fixtures and masks use its X/Y and % operators."""
    return core.akarin.Expr(clips, e, **kw)


def promote(c8):
    """The 8-bit capture at 16-bit with genuine sub-8-bit content: a smooth
    ripple of +-1.5 10-bit levels on luma and chroma. A 10-bit file made by
    converting an 8-bit master has zero low bits, and the old code was already
    bit-exact on it, which is why no existing test saw this."""
    c = core.resize.Point(c8, format=vs.YUV422P16)
    return _expr(c, ['x X 0.13 * Y 0.07 * + sin 96 * + 0 max 65535 min',
                     'x X 0.21 * Y 0.05 * - sin 96 * + 0 max 65535 min'])


def gradient():
    """A shallow horizontal luma ramp, 64 to 80 in 8-bit levels across the
    frame (four 10-bit steps per 8-bit level), flat chroma: where 8-bit
    quantisation shows as bands."""
    b = core.std.BlankClip(width=W, height=H, format=vs.YUV422P16, length=N,
                           color=[64 << 8, 32768, 32768])
    return _expr(b, ['X {} / 16 * 256 * 16384 +'.format(W - 1), 'x'])


def scratch(c):
    """Darken the scratch columns (multiplicative on luma), at the clip's depth."""
    e = 'x'
    for x, w, g in SCRATCHES:
        e = 'X {x} >= X {x2} < and x {g} * {e} ?'.format(x=x, x2=x + w, g=g, e=e)
    return _expr(c, [e, 'x'])


def to(c, fmt, rng):
    """At [fmt] in range [rng] ('limited' or 'full'), field-flagged TFF as the
    templates mark an interlaced source. Note _Range follows H.273's
    video_full_range_flag: 0 is limited, 1 is full."""
    c = core.resize.Point(c, format=fmt)
    c = core.std.SetFrameProps(c, _Range=1 if rng == 'full' else 0)
    return core.std.SetFieldBased(c, 2)


def descratch8(c8, **kw):
    """The plugin call as the block makes it, on an 8-bit clip."""
    if c8.format.subsampling_h == 0:
        return core.descratch.DeScratch(c8, **kw)
    blank = core.std.BlankClip(c8, width=c8.width // 2, format=vs.GRAY8, color=128, keep=True)
    luma = core.descratch.DeScratch(core.std.ShufflePlanes([c8, blank, blank], [0, 0, 0], vs.YUV), **kw)
    return core.std.ShufflePlanes([luma, c8], [0, 1, 2], vs.YUV)


def down(c):
    return core.resize.Bilinear(c, format=c.format.replace(bits_per_sample=8, sample_type=vs.INTEGER))


def old_block(c, **kw):
    """Before task #34: the whole 8-bit result up-converted."""
    if c.format.bits_per_sample == 8:
        return descratch8(c, **kw)
    return core.resize.Bilinear(descratch8(down(c), **kw), format=c.format)


def new_block(c, **kw):
    """Task #34: source + up(result) - up(8-bit input)."""
    if c.format.bits_per_sample == 8:
        return descratch8(c, **kw)
    c8 = down(c)
    up = lambda x: core.resize.Point(x, format=c.format)
    return _expr([c, up(descratch8(c8, **kw)), up(c8)], 'x y + z -')


def masked_block(c, **kw):
    """The alternative: the up-converted 8-bit result where the plugin changed
    a sample, the source elsewhere."""
    c8 = down(c)
    d8 = descratch8(c8, **kw)
    return _expr([c, d8, c8, core.resize.Point(d8, format=c.format)], 'y z = x a ?')


def count(mask, plane=0):
    """Samples of [plane] where an 8-bit 0/255 mask is set, over all frames."""
    st = core.std.PlaneStats(mask, plane=plane)
    w = mask.width >> (mask.format.subsampling_w if plane else 0)
    h = mask.height >> (mask.format.subsampling_h if plane else 0)
    return round(sum(st.get_frame(i).props['PlaneStatsAverage'] for i in range(mask.num_frames)) * w * h)


def mask8(clips, e):
    """An 8-bit 0/255 mask of the same layout from an expression over clips."""
    return _expr(clips, e, format=clips[0].format.replace(bits_per_sample=8).id)
