"""Task #87: does Bifrost v4.0 leave luma bit-exact? (If so, the sweep's
deltaOnly entry for it can say UntouchedPlanes([0]).) Compares Y in/out with
PlaneStats' PlaneStatsDiff (0.0 = identical) and counts changed chroma, at
8/10/16 bits x 4:2:0/4:2:2/4:4:4, progressive and interlaced=True."""
import vapoursynth as vs

core = vs.core

for bits in (8, 10, 12, 16):
    for ss in ((1, 1), (1, 0), (0, 0)):
        fmt = core.query_video_format(vs.YUV, vs.INTEGER, bits, *ss)
        peak = (1 << bits) - 1
        c = core.std.BlankClip(width=96, height=64, format=fmt.id, length=7)
        # luma with a moving checker (rainbow-like), chroma alternating per frame
        c = core.akarin.Expr(c, [f'X 3 * Y 5 * + N 7 * + 64 % {peak} * 96 / X Y + N + 2 % {peak} * 8 / +',
                                 f'{peak} 2 / X Y + N + 2 % 2 * 1 - {peak} * 10 / +'])
        for inter in (False, True):
            out = core.bifrost.Bifrost(c, luma_thresh=10.0, variation=5, interlaced=inter)
            y = core.std.PlaneStats(core.std.ShufflePlanes(out, 0, vs.GRAY),
                                    core.std.ShufflePlanes(c, 0, vs.GRAY))
            u = core.std.PlaneStats(core.std.ShufflePlanes(out, 1, vs.GRAY),
                                    core.std.ShufflePlanes(c, 1, vs.GRAY))
            yd = max(y.get_frame(n).props['PlaneStatsDiff'] for n in range(1, 6))
            ud = max(u.get_frame(n).props['PlaneStatsDiff'] for n in range(1, 6))
            print('%2d-bit %s interlaced=%-5s  Y diff %.6g   U diff %.6g' % (bits, fmt.name, inter, yd, ud))
