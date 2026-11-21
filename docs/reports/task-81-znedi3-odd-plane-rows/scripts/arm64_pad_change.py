"""What padding changes where the plugin did not need it (task #81).

On arm64 the template's _nnedi3() uses dubhater's nnedi3, which accepts a
720x486 4:2:0 frame unpadded. Since task #81 the frame is padded on every
platform (2 rows repeating each field's last row, cropped back), so arm64
runs the graph x86 must. This compares Bwdif + NNEDI3, as the template calls
it, with the unpadded call: per plane, which rows differ and by how much.
And it checks that a frame that already fits comes out the same as the
unpadded call (720x480 4:2:0, 720x486 4:2:2).

Run with the bundle's Python and environment (see reproduce.sh):
  arm64_pad_change.py RAW_YUV444P16 [frames]
RAW is interlaced_test.avi scaled to 720x486 as raw yuv444p16le.
"""
import ctypes
import json
import os
import sys

import vapoursynth as vs

core = vs.core
HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATES = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..', 'worker', 'templates'))
sys.path.insert(0, TEMPLATES)
import plugin_formats as _pf  # noqa: E402

raw, frames = sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 10
W, H = 720, 486


def source():
    blank = core.std.BlankClip(width=W, height=H, format=vs.YUV444P16, length=frames)
    fsize = W * H * 2 * 3

    def fill(n, f):
        o = f.copy()
        with open(raw, 'rb') as fh:
            fh.seek(n * fsize)
            data = fh.read(fsize)
        off = 0
        for p in range(3):
            base = ctypes.cast(o.get_write_ptr(p), ctypes.c_void_p).value
            st = o.get_stride(p)
            for y in range(H):
                ctypes.memmove(base + y * st, data[off:off + W * 2], W * 2)
                off += W * 2
        return o
    return core.std.ModifyFrame(blank, blank, fill)


# The template's helper, verbatim (every name it uses is defined here).
tpl = open(os.path.join(TEMPLATES, 'pipeline_template.vpy')).read().replace('\r\n', '\n')
start = tpl.index('import platform as _platform')
end = tpl.index('\n\n\n', tpl.index('def _nnedi3('))
ns = {'core': core, '_pf': _pf}
exec(tpl[start:end], ns)
_nnedi3 = ns['_nnedi3']
assert ns['_IS_ARM'], 'run on arm64: the unpadded call is refused elsewhere'


def bwdif(c, interp):
    return core.bwdif.Bwdif(c, field=3, edeint=interp(c, field=3, dh=False))


def raw_nnedi3(c, **kw):
    return core.nnedi3.nnedi3(c, **kw)


src444 = source()
out = {}
for bits in (8, 16):
    c = core.resize.Bicubic(src444, format=vs.YUV420P8 if bits == 8 else vs.YUV420P16,
                            dither_type='none')
    c = core.std.SetFieldBased(c, 2)
    padded, plain = bwdif(c, _nnedi3), bwdif(c, raw_nnedi3)
    # The reference for the rows that differ: Bwdif's own interpolator, the
    # same deinterlace without NNEDI3.
    ref = core.bwdif.Bwdif(c, field=3)
    scale = 1 << (bits - 8)
    planes = []
    for p in range(3):
        a = core.std.ShufflePlanes(padded, p, vs.GRAY)
        b = core.std.ShufflePlanes(plain, p, vs.GRAY)
        r = core.std.ShufflePlanes(ref, p, vs.GRAY)
        rows, maxd, n_diff, n_all = set(), 0, 0, 0
        last_a = last_b = 0.0
        n_last = 0
        for n in range(a.num_frames):
            fa, fb, fr = a.get_frame(n), b.get_frame(n), r.get_frame(n)
            la, lb, lr = fa[0].tolist(), fb[0].tolist(), fr[0].tolist()
            for y in range(fa.height):
                ra, rb = la[y], lb[y]
                d = max(abs(int(x) - int(z)) for x, z in zip(ra, rb))
                n_all += len(ra)
                if d:
                    rows.add(y)
                    maxd = max(maxd, d)
                    n_diff += sum(1 for x, z in zip(ra, rb) if x != z)
            for y in range(fa.height - 3, fa.height):
                last_a += sum(abs(x - z) for x, z in zip(la[y], lr[y]))
                last_b += sum(abs(x - z) for x, z in zip(lb[y], lr[y]))
                n_last += len(lr[y])
        planes.append({'plane': 'YUV'[p], 'height': a.height,
                       'rows_differing': sorted(rows),
                       'max_diff_levels': maxd / scale,
                       'samples_differing_pct': round(100.0 * n_diff / n_all, 4),
                       'last3_mean_abs_vs_plain_bwdif': {
                           'padded': round(last_a / n_last / scale, 3),
                           'unpadded': round(last_b / n_last / scale, 3)}})
    out['420p%d' % bits] = planes

# A frame that fits is the plugin's own output, sample for sample.
fits = {}
for name, fmt, h in (('420p8 720x480', vs.YUV420P8, 480), ('422p8 720x486', vs.YUV422P8, 486)):
    c = core.std.BlankClip(width=720, height=h, format=fmt, length=1)
    a, b = _nnedi3(c, field=1), raw_nnedi3(c, field=1)
    fits[name] = all(core.std.PlaneStats(a, b, plane=p).get_frame(0).props['PlaneStatsDiff'] == 0
                     for p in range(3))
out['unpadded_sizes_identical'] = fits
print(json.dumps(out))
