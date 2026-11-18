import sys
import vapoursynth as vs
from common import clip
core = vs.core
core.num_threads = 8
kw = dict(sigma=16, bt=1)
if sys.argv[1] == 'blank':
    c = core.std.BlankClip(width=720, height=480, format=vs.YUV420P8, length=10, color=[100, 128, 128])
else:
    c = clip('420', 8, 0, 720, 480, frames=10)
a = core.fft3dfilter.FFT3DFilter(c, **kw); b = core.fft3dfilter.FFT3DFilter(c, **kw)
for n in range(10):
    fa, fb = a.get_frame(n), b.get_frame(n)
    for p in range(3):
        w, h = fa.width if p == 0 else fa.width // 2, fa.height if p == 0 else fa.height // 2
        A, B = bytes(fa[p]), bytes(fb[p])
        rows, cols = {}, {}
        vals = []
        for y in range(h):
            ra, rb = A[y*w:(y+1)*w], B[y*w:(y+1)*w]
            for x in range(w):
                if ra[x] != rb[x]:
                    rows[y] = rows.get(y, 0) + 1; cols[x] = cols.get(x, 0) + 1
                    if len(vals) < 6: vals.append((x, y, ra[x], rb[x]))
        if rows:
            ys, xs = sorted(rows), sorted(cols)
            print(n, p, 'count', sum(rows.values()), 'rows', ys[0], '..', ys[-1], len(ys), 'cols', xs[0], '..', xs[-1], len(xs), vals)
