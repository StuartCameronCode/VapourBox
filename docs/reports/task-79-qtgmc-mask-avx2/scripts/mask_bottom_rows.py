# MVTools Mask: are the rows under the block grid a copy of the row above
# (task #79)? Prints (nHeightB, luma stride, wrong rows over frames 1-5).
# Run with the bundle's Python (see mask_depths.py).
import vapoursynth as vs, sys
core = vs.core
def run(w, h, b, o):
    c = core.std.BlankClip(width=w, height=h, format=vs.YUV420P8, length=6, color=[100,128,128])
    c = core.grain.Add(c, var=300, constant=False, seed=3)
    sup = core.mv.Super(c, pel=2)
    bv = core.mv.Analyse(sup, isb=True, blksize=b, overlap=o)
    m = core.mv.Mask(c, bv, kind=1, ml=10, thscd1=16320)
    nby = (h - o) // (b - o); hb = nby * (b - o) + o
    bad = 0
    for n in range(1, 6):
        f = m.get_frame(n); y = bytes(f[0])
        row = lambda r: y[r * w:(r + 1) * w]
        ref = row(hb - 1)
        bad += sum(1 for r in range(hb, h) if row(r) != ref)
    return hb, f.get_stride(0), bad
for w, h, b, o in [(128, 96, 32, 8), (136, 96, 32, 8), (104, 96, 32, 8), (1920, 1080, 32, 16), (1280, 720, 32, 8), (1920, 1080, 16, 8)]:
    print(w, h, b, o, 'nHeightB/stride/rows wrong:', run(w, h, b, o))
