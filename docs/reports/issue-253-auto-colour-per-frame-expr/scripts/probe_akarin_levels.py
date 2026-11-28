"""Issue #253: can auto levels be one akarin expression that reads the measured
black and white points from frame properties, bit-identical to std.Levels?

No. std.Levels builds a lookup table from IEEE float arithmetic
(R78 genericfilters.cpp: clamp, (v - min_in) / (max_in - min_in), * range,
+ min_out, clamp, + 0.5, truncate). The same arithmetic in akarin.Expr is
compiled with fast-math, which turns the division into a multiplication by a
reciprocal; where the exact result is a .5 tie (e.g. 55 / 110 * 219 + 16 =
125.5) the reciprocal's rounding drops it to 125.4999 and the output one level.

For seeded random (lo, hi) pairs at 8 bits and three output ranges, this
counts the pairs where any input sample differs from std.Levels, for three
spellings of the expression and both settings of akarin's `opt`.

Usage: as probe_exact.py, with just <deps>.
"""
import random
import sys

sys.path.insert(0, sys.argv[1])
import vapoursynth as vs  # noqa: E402

core = vs.core
base = core.std.BlankClip(width=256, height=2, format=vs.YUV420P8, length=1)
ramp = core.akarin.Expr(base, ['X', '', ''])
L, H = 'x._L', 'x._H'
variants = {
    'ternary (flat frame kept)':
        lambda lt, ht: f'{H} {L} <= x x {L} max {H} min {L} - {H} {L} - / {ht - lt} * {lt} + 0.5 + floor 0 max 255 min ?',
    'plain':
        lambda lt, ht: f'x {L} max {H} min {L} - {H} {L} - / {ht - lt} * {lt} + 0.5 + floor 0 max 255 min',
    'clamp, +0.5, trunc (std.Levels order)':
        lambda lt, ht: f'x {L} max {H} min {L} - {H} {L} - / {ht - lt} * {lt} + 0 max 255 min 0.5 + trunc',
}
rng = random.Random(1)
bad = {(k, o): 0 for k in variants for o in (0, 1)}
cases = 0
example = None
for _ in range(1500):
    lo, hi = sorted(rng.randrange(256) for _ in range(2))
    if lo == hi:
        continue
    for lt, ht in ((16, 235), (0, 255), (40, 200)):
        ref = core.std.Levels(ramp, min_in=lo, max_in=hi, min_out=lt, max_out=ht, planes=[0]).get_frame(0)[0]
        st = core.std.SetFrameProps(ramp, _L=lo, _H=hi)
        cases += 1
        for k, f in variants.items():
            for o in (0, 1):
                out = core.akarin.Expr(st, [f(lt, ht), '', ''], opt=o).get_frame(0)[0]
                diff = [v for v in range(256) if out[0, v] != ref[0, v]]
                if diff:
                    bad[(k, o)] += 1
                    if example is None:
                        v = diff[0]
                        example = (lo, hi, lt, ht, v, ref[0, v], out[0, v])
print(f'(lo, hi, output range) cases: {cases}')
for (k, o), n in bad.items():
    print(f'{k:40s} opt={o}: {n} cases differ ({100.0 * n / cases:.1f}%)')
if example:
    lo, hi, lt, ht, v, r, a = example
    print(f'example: min_in={lo} max_in={hi} min_out={lt} max_out={ht} input {v}: '
          f'std.Levels {r}, akarin {a}')
