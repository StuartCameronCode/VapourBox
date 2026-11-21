import sys, vapoursynth as vs; from vsutil_np import plane_rows, md5
core = vs.core
bits = int(sys.argv[1])
fmt = vs.GRAY8 if bits == 8 else vs.GRAY16
peak = (1 << bits) - 1
base = core.std.BlankClip(width=48, height=33, format=fmt, length=1)
base = core.akarin.Expr(base, f"X 7 * Y 13 * + 37 % {peak} * 36 /") if hasattr(core,'akarin') else core.std.Expr(base, f"X 7 * Y 13 * + 37 % {peak} * 36 /")
for fb in (0, 2):
    c = core.std.SetFieldBased(base, fb)
    for name, op in [('shift', lambda c: core.resize.Spline36(c, src_top=-0.5, src_left=1.0)),
                     ('up', lambda c: core.resize.Bicubic(c, 48, 66)),]:
        try:
            f = op(c).get_frame(0)
            a = plane_rows(f, 0)
            print(fb, name, (len(a), len(a[0])), 'rows-1..', a[-1][:8], 'md5', md5(a))
        except vs.Error as e:
            print(fb, name, 'ERR', e)
