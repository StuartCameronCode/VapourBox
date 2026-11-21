"""Task #87: is the last chroma row of a field-flagged 96x66 4:2:0 frame
written, before (the bare call) and after (the call through pad_around, as
the template and autochromafix.py now make it)?

The source's chroma is computed into [peak/4, 3*peak/4] over a BlankClip whose
chroma is 0, so a row nobody wrote reads 0 (a reused frame buffer) or other
leftovers, almost never a whole row inside that band. Usage:
    python lastrow.py   (with worker/templates on PYTHONPATH)
"""
import vapoursynth as vs
import plugin_formats as pf
import autochromafix

core = vs.core


def src(bits, h, fb):
    fmt = core.query_video_format(vs.YUV, vs.INTEGER, bits, 1, 1)
    peak = (1 << bits) - 1
    c = core.std.BlankClip(width=96, height=h, format=fmt.id, length=5, color=[peak // 2, 0, 0])
    lo, span = peak // 4, peak // 2
    c = core.akarin.Expr(c, ['', f'X 7 * Y 13 * + N 5 * + 37 % {span} * 36 / {lo} +'])
    return core.std.SetFieldBased(c, fb), lo, lo + span


def bwdif(c, field):
    return core.bwdif.Bwdif(c, field=field)


def shift(c):
    planes = [core.std.ShufflePlanes(c, i, vs.GRAY) for i in range(3)]
    for i in (1, 2):
        planes[i] = core.resize.Spline36(planes[i], src_left=0.5, src_top=-0.5)
    return core.std.ShufflePlanes(planes, [0, 0, 0], vs.YUV)


def shift_padded(c):
    planes = [core.std.ShufflePlanes(c, i, vs.GRAY) for i in range(3)]
    for i in (1, 2):
        planes[i] = pf.pad_around(planes[i], lambda p: core.resize.Spline36(p, src_left=0.5, src_top=-0.5),
                                  height_step=2, field_based_only=True)
    return core.std.ShufflePlanes(planes, [0, 0, 0], vs.YUV)


CASES = [
    ('bwdif field=3', lambda c: bwdif(c, 3),
     lambda c: pf.pad_around(c, lambda x: bwdif(x, 3), height_step=pf.CHROMA)),
    ('bwdif field=1', lambda c: bwdif(c, 1),
     lambda c: pf.pad_around(c, lambda x: bwdif(x, 1), height_step=pf.CHROMA)),
    ('chroma shift', shift, shift_padded),
    ('autochroma _shift_chroma', None, lambda c: autochromafix._shift_chroma(c, 1.0, -1.0)),
]


def last_row_ok(clip, lo, hi, plane):
    f = clip.get_frame(2)
    m = memoryview(f[plane])
    row = [m[m.shape[0] - 1, x] for x in range(m.shape[1])]
    return all(lo - 2 <= v <= hi + 2 for v in row), row[:6]


if __name__ == '__main__':
    for bits in (8, 10, 16):
        for h in (64, 66):
            for fb in (0, 2):
                for name, before, after in CASES:
                    for tag, fn in (('before', before), ('after', after)):
                        if fn is None:
                            continue
                        c, lo, hi = src(bits, h, fb)
                        ok = all(last_row_ok(fn(c), lo, hi, p)[0] for p in (1, 2))
                        print('%2d-bit 96x%d fb=%d %-26s %-6s %s' % (
                            bits, h, fb, name, tag, 'written' if ok else 'NOT WRITTEN %s' % (last_row_ok(fn(c), lo, hi, 1)[1],)))


def rows_diff(a, b, plane):
    """(max |a-b| over every chroma row but the last, max over the last)."""
    fa, fb = a.get_frame(2), b.get_frame(2)
    ma, mb = memoryview(fa[plane]), memoryview(fb[plane])
    h, w = ma.shape
    body = max(abs(int(ma[y, x]) - int(mb[y, x])) for y in range(h - 1) for x in range(w))
    last = max(abs(int(ma[h - 1, x]) - int(mb[h - 1, x])) for x in range(w))
    return body, last


def compare():
    """Before vs after: every row but the last must agree exactly (the padding
    reproduces the edge handling); the last row is where 'before' was not
    written."""
    print('\nbefore vs after, plane U: (max diff above the last row, on the last row)')
    for bits in (8, 10, 16):
        for h in (64, 66):
            for fb in (0, 2):
                for name, before, after in CASES:
                    if before is None:
                        continue
                    c, _, _ = src(bits, h, fb)
                    print('%2d-bit 96x%d fb=%d %-14s %s' % (bits, h, fb, name, rows_diff(before(c), after(c), 1)))


compare()
