import vapoursynth as vs
from vsutil_np import plane_rows, md5
core = vs.core
def src(h, bits):
    fmt = core.query_video_format(vs.YUV, vs.INTEGER, bits, 1, 1)
    peak = (1 << bits) - 1
    c = core.std.BlankClip(width=96, height=h, format=fmt.id, length=3)
    return core.akarin.Expr(c, f"X 7 * Y 13 * + N 5 * + 61 % {peak} * 60 / X Y * 3 % +")
def sig(c):
    f = c.get_frame(1)
    return md5([plane_rows(f, p) for p in range(3)])
for h in (64, 480, 66):
    for bits, to in ((16, 8), (10, 8), (16, 10)):
        s = src(h, bits)
        tgt = s.format.replace(bits_per_sample=to).id
        r = {}
        for fb in (0, 2):
            c = core.std.SetFieldBased(s, fb)
            try:
                down = core.resize.Bilinear(c, format=tgt)
                back = core.resize.Point(down, format=s.format.id)
                r[fb] = (sig(down), sig(back))
            except vs.Error as e:
                r[fb] = ('ERR ' + str(e)[:60],)
        # flag stripped
        c = core.std.SetFieldBased(s, 2)
        st = core.std.RemoveFrameProps(c, '_FieldBased')
        down = core.resize.Bilinear(st, format=tgt)
        r['strip'] = (sig(down), sig(core.resize.Point(down, format=s.format.id)))
        print(h, bits, '->', to, r)
