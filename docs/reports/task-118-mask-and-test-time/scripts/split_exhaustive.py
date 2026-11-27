# The split reference against upstream's own 10-bit table on every pair of
# 10-bit values (1,048,576), and each one's cost per call. The test makes the
# same check once per run. Run as profile_reference.py (vspipe -i ... -).
import sys
import time
import vapoursynth as vs
core = vs.core


def upstream_table(a, b):
    ba, bb = a.format.bits_per_sample, b.format.bits_per_sample
    return core.std.Lut2(a, b, lut=[x & y for y in range(1 << bb) for x in range(1 << ba)])


AND8 = [x & y for y in range(256) for x in range(256)]


def split(a, b):
    bits = a.format.bits_per_sample
    s, m = bits - 8, (1 << (bits - 8)) - 1
    hi = [v >> s for v in range(1 << bits)]
    lo = [v & m for v in range(1 << bits)]
    h = core.std.Lut2(core.std.Lut(a, lut=hi, bits=8), core.std.Lut(b, lut=hi, bits=8), lut=AND8)
    l = core.std.Lut2(core.std.Lut(a, lut=lo, bits=8), core.std.Lut(b, lut=lo, bits=8), lut=AND8)
    return core.std.Lut2(h, l, lut=[(x << s) | y for y in range(256) for x in range(256)], bits=bits)


row = core.std.StackHorizontal([core.std.BlankClip(format=vs.GRAY10, width=1, height=1, length=1, color=[v]) for v in range(1024)])
a = core.std.StackVertical([row] * 1024)
b = core.std.Transpose(a)
for name, c in (('a', a), ('b', b)):
    p = core.std.PlaneStats(c).get_frame(0).props
    print('ramp %s spans %d..%d' % (name, p['PlaneStatsMin'], p['PlaneStatsMax']), file=sys.stderr)
t = time.perf_counter()
want = upstream_table(a, b)
t_table = time.perf_counter() - t
t = time.perf_counter()
got = split(a, b)
t_split = time.perf_counter() - t
d = core.std.PlaneStats(got, want).get_frame(0).props['PlaneStatsDiff']
print('upstream table %.3f s a call, split %.4f s a call, PlaneStatsDiff %r, format %s'
      % (t_table, t_split, d, got.format.name), file=sys.stderr)
core.std.BlankClip().set_output()
