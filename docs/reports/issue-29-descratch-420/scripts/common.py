"""Shared helpers: load a raw planar 8-bit YUV file as a clip (no source
plugin, no numpy), the carrier, and per-plane comparisons."""
import ctypes
import vapoursynth as vs

core = vs.core
W, H, N = 720, 576, 24


def load(path, fmt):
    data = open(path, 'rb').read()
    blank = core.std.BlankClip(width=W, height=H, format=fmt, length=N)
    fi = blank.format
    sizes = [(W >> (fi.subsampling_w if p else 0), H >> (fi.subsampling_h if p else 0)) for p in range(3)]
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


def carrier(c, **kw):
    """What the templates do for 4:2:0: luma on a 4:2:2 copy with blank chroma."""
    blank = core.std.BlankClip(c, width=c.width // 2, format=vs.GRAY8, color=128, keep=True)
    car = core.std.ShufflePlanes([c, blank, blank], [0, 0, 0], vs.YUV)
    return core.std.ShufflePlanes([core.descratch.DeScratch(car, **kw), c], [0, 1, 2], vs.YUV)


def native(c, **kw):
    return core.descratch.DeScratch(c, **kw)


def progressive(c, **kw):
    out = core.descratch.DeScratch(core.std.SetFieldBased(c, 0), **kw)
    return core.std.CopyFrameProps(out, c, props=['_FieldBased'])


def per_field(c, **kw):
    s = core.std.SeparateFields(c, tff=True)
    return core.std.DoubleWeave(core.descratch.DeScratch(s, **kw), tff=True)[::2]


def mae(a, b, x=None, w=None, plane=0):
    """Mean absolute difference in 8-bit levels, over all frames."""
    if x is not None:
        a = core.std.CropAbs(a, w, a.height, x, 0)
        b = core.std.CropAbs(b, w, b.height, x, 0)
    st = core.std.PlaneStats(a, b, plane=plane)
    return sum(st.get_frame(i).props['PlaneStatsDiff'] for i in range(a.num_frames)) / a.num_frames * 255


def differing(a, b, plane):
    """Number of frames in which any sample of `plane` differs."""
    e = core.std.Expr([a, b], ['x y = 0 255 ?'] * 3)
    st = core.std.PlaneStats(e, plane=plane)
    return sum(1 for i in range(a.num_frames) if st.get_frame(i).props['PlaneStatsMax'] > 0)
