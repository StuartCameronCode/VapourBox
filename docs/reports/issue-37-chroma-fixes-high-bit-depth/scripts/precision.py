"""Every number in the report.

    precision.py CAPTURE_YUV422P IMG_DIR

Section 1/2: per filter, fixture, format and range, the samples the filter
changes at its working depth, the samples each guard leaves non-identical to
the source, whether the new guard's changed set is the low-depth run's, the
largest distance from the low-depth result and the low bits lost.
Section 3: removal against the clean picture. Section 4: banding on a ramp.
Writes 16-bit-stretched crops to IMG_DIR as raw gray."""
import sys
import vapoursynth as vs
from common import (core, W, H, load8, promote, static, artefacts, gradient, to, FILTERS,
                    down, old_block, new_block, planes, count, mask8, _expr)

cap8 = load8(sys.argv[1])
img = sys.argv[2]
FIXTURES = [('capture', promote(cap8)), ('artefacts', promote(artefacts(cap8)))]
FMTS = {8: [(vs.YUV422P10, 'limited'), (vs.YUV422P10, 'full'), (vs.YUV420P10, 'limited'),
            (vs.YUV422P12, 'limited'), (vs.YUV444P16, 'limited')],
        10: [(vs.YUV422P12, 'limited'), (vs.YUV422P12, 'full'), (vs.YUV420P12, 'limited'),
             (vs.YUV444P16, 'limited')]}


def pct(a, tot):
    return ' / '.join(f'{100 * x / t:.2f}' for x, t in zip(a, tot))


def maxdev(out, ref, step):
    st = core.std.PlaneStats(core.std.Expr([out, ref], 'x y - abs'))
    return max(st.get_frame(i).props['PlaneStatsMax'] for i in range(out.num_frames)) / step


print('== 1-2. what each guard does to a deeper source')
print('fixture | filter | format | range | changed at low depth Y/U/V % | old non-exact Y/U/V % | '
      'new non-exact Y/U/V % | new set = low set | new max from low result (low lv) | '
      'low bits lost old / new (samples)')
for fx, clean in FIXTURES:
    for name, (bits, filt) in FILTERS.items():
        for fmt, rng in FMTS[bits]:
            src = to(clean, fmt, rng)
            if name.startswith('LUT'):
                src = core.std.SetFieldBased(src, 0)  # havsfunc: frame-based only
            lo = down(src, bits)
            rlo = filt(lo)
            tot = planes(src)
            step = 1 << (src.format.bits_per_sample - bits)
            changed = [count(mask8([lo, rlo], 'x y = 0 255 ?'), p) for p in range(3)]
            old, new = old_block(name, src), new_block(name, src)
            ne_old = [count(mask8([src, old], 'x y = 0 255 ?'), p) for p in range(3)]
            ne_new = [count(mask8([src, new], 'x y = 0 255 ?'), p) for p in range(3)]
            setdiff = sum(count(mask8([src, new, lo, rlo], 'x y = 1 0 ? z a = 1 0 ? = 0 255 ?'), p)
                          for p in range(3))
            dev = maxdev(new, core.resize.Point(rlo, format=src.format.id), step)
            if rng == 'limited':
                lost = [sum(count(mask8([src, o], f'x y - abs {step} % 0 = 0 255 ?'), p) for p in range(3))
                        for o in (old, new)]
                lost_s = f'{lost[0]} / {lost[1]}'
            else:
                lost_s = 'n/a (full range scales by (2^n-1)/(2^m-1))'
            print(f'{fx} | {name} | {src.format.name} | {rng} | {pct(changed, tot)} | {pct(ne_old, tot)} | '
                  f'{pct(ne_new, tot)} | {"yes" if setdiff == 0 else f"NO ({setdiff})"} | {dev:.2f} | {lost_s}',
                  flush=True)

print('\n== 3. removal: mean |out - clean| per plane, 8-bit levels, artefacts fixture')
print('filter | format | injected (no filter) | low-depth run | old guard | new guard')
for name, (bits, filt) in FILTERS.items():
    fmt = vs.YUV422P10 if bits == 8 else vs.YUV422P12
    gt = to(promote(static(cap8)), fmt, 'limited')
    src = to(promote(artefacts(cap8)), fmt, 'limited')
    if name.startswith('LUT'):
        gt, src = core.std.SetFieldBased(gt, 0), core.std.SetFieldBased(src, 0)
    lo = down(src, bits)

    def mae(c, ref):
        out = []
        for p in range(3):
            st = core.std.PlaneStats(c, ref, plane=p)
            out.append(sum(st.get_frame(i).props['PlaneStatsDiff'] for i in range(1, c.num_frames - 1))
                       / (c.num_frames - 2) * 255)
        return ' / '.join(f'{x:.3f}' for x in out)
    print(f'{name} | {src.format.name} | {mae(src, gt)} | {mae(filt(lo), down(gt, bits))} | '
          f'{mae(old_block(name, src), gt)} | {mae(new_block(name, src), gt)}', flush=True)

print('\n== 4. banding: distinct luma values on row 288 of a 64..80 ramp (luma untouched by both)')
for name, fmt in [('Bifrost', vs.YUV422P10), ('Bifrost', vs.YUV422P16), ('LUTDeRainbow', vs.YUV422P12),
                  ('LUTDeRainbow', vs.YUV422P16)]:
    src = to(gradient(), fmt, 'limited')
    if name.startswith('LUT'):
        src = core.std.SetFieldBased(src, 0)
    vals = {}
    for label, c in [('source', src), ('old', old_block(name, src)), ('new', new_block(name, src))]:
        f = c.get_frame(6)
        vals[label] = len({f[0][288, x] for x in range(W)})
    print(f'{name} | {src.format.name} | ' + ' | '.join(f'{k} {v}' for k, v in vals.items()), flush=True)

# Images. Ramp crops through Bifrost at 10-bit, luma stretched 16x (64 10-bit
# levels -> 0..255), and |out - src| x64 on the capture for DeDot at 10-bit.
src = to(gradient(), vs.YUV422P10, 'limited')
for label, c in [('1_source', src), ('2_old', old_block('Bifrost', src)), ('3_new', new_block('Bifrost', src))]:
    c = core.std.CropAbs(c, 160, 120, 280, 240)
    s = core.std.Expr(core.std.ShufflePlanes(c, 0, vs.GRAY), 'x 256 - 4 *', format=vs.GRAY8)
    f = s.get_frame(6)
    with open(f'{img}/ramp_bifrost_{label}.gray', 'wb') as fh:
        for y in range(120):
            fh.write(bytes(f[0][y, x] for x in range(160)))
src = to(promote(cap8), vs.YUV422P10, 'limited')
for label, blk in [('4_old', old_block), ('5_new', new_block)]:
    c = core.std.CropAbs(src, 160, 120, 280, 240)
    o = core.std.CropAbs(blk('DeDot', src), 160, 120, 280, 240)
    d = core.std.Expr([core.std.ShufflePlanes(c, 0, vs.GRAY), core.std.ShufflePlanes(o, 0, vs.GRAY)],
                      'x y - abs 64 *', format=vs.GRAY8)
    f = d.get_frame(6)
    with open(f'{img}/capture_dedot_diff_{label}.gray', 'wb') as fh:
        for y in range(120):
            fh.write(bytes(f[0][y, x] for x in range(160)))
