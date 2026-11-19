"""How far measure=0 moves the picture from measure=1 (today's default), on
real footage. measure=0 is planned first, so its plans are its own (MEASURE
never reuses an ESTIMATE plan). Prints per call and depth: max abs diff and
share of samples differing (in the clip's own levels, and in 8-bit levels for
16-bit), mean abs diff, PSNR. argv: none."""
import json
import math

from common import CASES, core, fixture

core.num_threads = 8
res = {}
for bits in (8, 16):
    src = fixture(720, 480, 20, bits)
    peak = (1 << bits) - 1
    for name, fn in CASES.items():
        a, b = fn(src, 0), fn(src, 1)
        n = diff = 0
        mx = 0
        sad = 0
        sse = 0
        for fa, fb in zip(a.frames(prefetch=8), b.frames(prefetch=8)):
            for p in range(3):
                va, vb = bytes(fa[p]), bytes(fb[p])
                if bits == 8:
                    xa, xb = va, vb
                else:
                    xa = memoryview(va).cast('H')
                    xb = memoryview(vb).cast('H')
                for x, y in zip(xa, xb):
                    d = x - y if x > y else y - x
                    if d:
                        diff += 1
                        sad += d
                        sse += d * d
                        if d > mx:
                            mx = d
                n += len(xa)
        scale = 1 if bits == 8 else 1 / 257
        res['%s %d' % (name, bits)] = {
            'max_abs': mx, 'max_abs_8bit': round(mx * scale, 3),
            'pct_differ': round(100 * diff / n, 4),
            'mean_abs_8bit': round(sad / n * scale, 5),
            'psnr_db': (round(10 * math.log10(peak * peak / (sse / n)), 2) if sse else None)}
print(json.dumps(res, sort_keys=True))
