"""Which sample std.Convolution reads beyond the edge: a ramp 1, 11, 21, ...
shifted by one and two samples each way."""
import vapoursynth as vs

core = vs.core
c = core.akarin.Expr(core.std.BlankClip(width=8, height=8, format=vs.GRAY8, length=1), 'X 10 * 1 +') \
    if hasattr(core, 'akarin') else None
row = [1 + 10 * x for x in range(8)]
if c is None:
    c = core.std.BlankClip(width=8, height=8, format=vs.GRAY8, length=1)
    c = core.std.ModifyFrame(c, c, lambda n, f: _fill(f))


def _fill(f):
    f = f.copy()
    for y in range(8):
        for x in range(8):
            f[0][y, x] = row[x]
    return f


print('source             ', row)
for label, m in (('reads x-2', [1, 0, 0, 0, 0]), ('reads x-1', [1, 0, 0]),
                 ('reads x+1', [0, 0, 1]), ('reads x+2', [0, 0, 0, 0, 1])):
    f = core.std.Convolution(c, matrix=m, mode='h', divisor=1).get_frame(0)[0]
    print(f'{label:19s}', [f[0, x] for x in range(8)])
print("TCanny's rule: x = -i reads x = i, x = w-1+i reads w-1-i (edge not repeated)")
