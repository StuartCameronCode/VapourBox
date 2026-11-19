"""Task #75: a lut= list indexed x + (y << bits_a) gives exactly what function= gives (asymmetric f, mixed depths)."""
import vapoursynth as vs
core = vs.core
for fa, fb in ((vs.GRAY10, vs.GRAY10), (vs.GRAY8, vs.GRAY10)):
    a = core.grain.Add(core.std.BlankClip(format=fa, width=64, height=64, length=2), var=500, seed=1)
    b = core.grain.Add(core.std.BlankClip(format=fb, width=64, height=64, length=2), var=500, seed=2)
    f = lambda x, y: max(0, min(1023 if fa == vs.GRAY10 else 255, x * 3 - y // 2))
    r1 = core.std.Lut2(a, b, function=f)
    ba, bb = fa.bits_per_sample if hasattr(fa,'bits_per_sample') else a.format.bits_per_sample, b.format.bits_per_sample
    lut = [f(x, y) for y in range(1 << bb) for x in range(1 << a.format.bits_per_sample)]
    r2 = core.std.Lut2(a, b, lut=lut)
    print(a.format.name, b.format.name, 'identical:', core.std.PlaneStats(r1, r2).get_frame(0).props['PlaneStatsDiff'] == 0, r1.format.name, r2.format.name)
