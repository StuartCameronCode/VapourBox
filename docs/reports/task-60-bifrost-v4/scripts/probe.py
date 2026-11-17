"""Bifrost probe: one process, the bifrost the core autoloads.
Usage: probe.py FIXDIR OUT.json MODE
MODE: hashes  -> per case, per frame md5 of the whole frame and of the whole-block region
      arrays  -> dumps raw planes for parity analysis (npz-less: raw bytes files)
"""
import ctypes, hashlib, json, os, sys
import vapoursynth as vs
core = vs.core
FIX, OUT, MODE = sys.argv[1], sys.argv[2], sys.argv[3]
N = 12
SS = {'420': (1, 1), '422': (1, 0), '444': (0, 0)}


def source(w, h):
    path = os.path.join(FIX, 'src_%dx%d.yuv' % (w, h))
    blank = core.std.BlankClip(width=w, height=h, format=vs.YUV444P16, length=N, fpsnum=30000, fpsden=1001)
    fsize = w * h * 6

    def fill(n, f):
        o = f.copy()
        with open(path, 'rb') as fh:
            fh.seek(n * fsize)
            data = fh.read(fsize)
        off = 0
        for p in range(3):
            base = ctypes.cast(o.get_write_ptr(p), ctypes.c_void_p).value
            st = o.get_stride(p)
            for y in range(h):
                ctypes.memmove(base + y * st, data[off:off + w * 2], w * 2)
                off += w * 2
        return o
    return core.std.ModifyFrame(blank, blank, fill)


def shimmer(c16):
    # alternating chroma offset frame to frame (+-12 8-bit levels): rainbow that shimmers
    up = core.std.Expr(c16, ['', 'x 3072 +', 'x 3072 -'])
    dn = core.std.Expr(c16, ['', 'x 3072 -', 'x 3072 +'])
    return core.std.Interleave([core.std.SelectEvery(up, 2, 0), core.std.SelectEvery(dn, 2, 1)])


def make(w, h, ss, bits, zero_low=False):
    c = shimmer(source(w, h))
    sw, sh = SS[ss]
    if zero_low:
        f8 = core.query_video_format(vs.YUV, vs.INTEGER, 8, sw, sh)
        c = core.resize.Point(c, format=f8.id, dither_type='none')
    fmt = core.query_video_format(vs.YUV, vs.INTEGER, bits, sw, sh)
    c = core.resize.Point(c, format=fmt.id, dither_type='none')
    return core.std.SetFrameProps(c, _Matrix=6, _Range=0, _ChromaLocation=0)


def frame_md5(f, crop=None):
    m = hashlib.md5()
    for p in range(f.format.num_planes):
        w, h = f.width if p == 0 else f.width >> f.format.subsampling_w, f.height if p == 0 else f.height >> f.format.subsampling_h
        if crop:
            cw, ch = crop
            if p:
                cw >>= f.format.subsampling_w
                ch >>= f.format.subsampling_h
            w, h = cw, ch
        bps = f.format.bytes_per_sample
        base = ctypes.cast(f.get_read_ptr(p), ctypes.c_void_p).value
        st = f.get_stride(p)
        for y in range(h):
            m.update(ctypes.string_at(base + y * st, w * bps))
    return m.hexdigest()


def whole_blocks(w, h, interlaced):
    bw = (w // 4) * 4
    if interlaced:
        bh = ((h // 2) // 4) * 4 * 2
    else:
        bh = (h // 4) * 4
    return bw, bh


res = {}
if MODE == 'hashes':
    for (w, h) in [(96, 64), (98, 64), (352, 240), (718, 480), (720, 480), (720, 486)]:
        for ss in ('420', '422', '444'):
            for il in (True, False):
                key = '%dx%d %s il=%d' % (w, h, ss, il)
                try:
                    c = make(w, h, ss, 8)
                    o = core.bifrost.Bifrost(c, luma_thresh=10.0, variation=5, interlaced=il)
                    crop = whole_blocks(w, h, il)
                    fr = [o.get_frame(n) for n in range(N)]
                    res[key] = {'full': [frame_md5(f) for f in fr],
                                'blocks': [frame_md5(f, crop) for f in fr],
                                'changed': [frame_md5(f) != frame_md5(c.get_frame(i)) for i, f in enumerate(fr)]}
                except Exception as e:
                    res[key] = {'error': str(e).splitlines()[0]}
elif MODE == 'depths':
    for bits in (8, 9, 10, 12, 14, 16):
        for ss in ('420', '422', '444'):
            key = '%d %s' % (bits, ss)
            try:
                o = core.bifrost.Bifrost(make(352, 240, ss, bits), interlaced=True)
                o.get_frame(5)
                res[key] = 'ok'
            except Exception as e:
                res[key] = str(e).splitlines()[0]
    json.dump(res, open(OUT, 'w'), indent=1)
    sys.exit()
elif MODE == 'dump':
    # raw planes, frames 2..9, for parity: 8-bit, 16-bit with zero low bits, 16-bit genuine
    d = OUT + '.d'
    os.makedirs(d, exist_ok=True)
    w, h = 720, 480
    for ss in ('420', '422'):
        for tag, bits, zl in (('b8', 8, False), ('b16z', 16, True), ('b16', 16, False), ('b10', 10, False)):
            src = make(w, h, ss, bits, zl)
            o = core.bifrost.Bifrost(src, interlaced=True)
            for name, clip in (('in', src), ('out', o)):
                with open(os.path.join(d, '%s_%s_%s.raw' % (ss, tag, name)), 'wb') as fh:
                    for n in range(2, 10):
                        f = clip.get_frame(n)
                        for p in range(3):
                            pw = f.width >> (f.format.subsampling_w if p else 0)
                            ph = f.height >> (f.format.subsampling_h if p else 0)
                            base = ctypes.cast(f.get_read_ptr(p), ctypes.c_void_p).value
                            st = f.get_stride(p)
                            for y in range(ph):
                                fh.write(ctypes.string_at(base + y * st, pw * f.format.bytes_per_sample))
    res['ok'] = True
json.dump(res, open(OUT, 'w'))
