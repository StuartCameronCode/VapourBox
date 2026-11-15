"""Sections 2-4: what each version of the block does to a >8-bit source.

    precision.py CAPTURE_YUV422P IMG_DIR

For each fixture and format: the share of samples each version changes, whether
the changed set is the 8-bit run's, the largest distance from the 8-bit repair,
the scratch left behind against the clean picture, and whether the source's
low bits survive. Writes 16-bit-stretched crops to IMG_DIR as raw gray."""
import sys
import vapoursynth as vs
from common import (core, W, H, SCRATCHES, load8, promote, gradient, scratch, to, down,
                    descratch8, old_block, new_block, masked_block, count, mask8)

cap = promote(load8(sys.argv[1]))
img = sys.argv[2]
VARIANTS = [('current', old_block), ('delta (fix)', new_block), ('masked', masked_block)]
FORMATS = [(vs.YUV422P10, 'limited'), (vs.YUV420P10, 'limited'), (vs.YUV422P12, 'limited'),
           (vs.YUV444P16, 'limited'), (vs.YUV422P10, 'full')]


def removal(out, gt):
    """Mean |out - clean| over an 8-px strip around each scratch, in 8-bit levels."""
    tot = n = 0
    for x, w, _ in SCRATCHES:
        x0 = (x + w // 2 - 4) & ~1
        a = core.std.CropAbs(out, 8, out.height, x0, 0)
        b = core.std.CropAbs(gt, 8, gt.height, x0, 0)
        st = core.std.PlaneStats(a, b)
        for i in range(out.num_frames):
            tot += st.get_frame(i).props['PlaneStatsDiff']
            n += 1
    return tot / n * 255


def row(clip, y, x0, x1, frame=0):
    f = clip.get_frame(frame)
    m = f[0]
    return [m[y, x] for x in range(x0, x1)]


for name, clean in [('capture', cap), ('gradient', gradient())]:
    print(f'\n== {name}')
    print('format | range | variant | non-exact Y % | non-exact U/V % | set = 8-bit run | '
          'max from 8-bit repair (8-bit lv) | scratch left (8-bit lv) | low bits lost (samples)')
    for fmt, rng in FORMATS:
        gt = to(clean, fmt, rng)
        src = to(scratch(clean), fmt, rng)
        bits = src.format.bits_per_sample
        step = 1 << (bits - 8)
        o8 = down(src)
        d8 = descratch8(o8)
        changed8 = count(mask8([o8, d8], 'x y = 0 255 ?'))
        left8 = removal(d8, down(gt))
        total = W * H * src.num_frames
        cw = W >> src.format.subsampling_w
        ch = H >> src.format.subsampling_h
        ctotal = cw * ch * src.num_frames
        fname = f'{src.format.name} | {rng}'
        print(f'{fname} | 8-bit run | {changed8 / total * 100:.3f} | 0 | - | - | {left8:.3f} | -')
        up = core.resize.Point(d8, format=src.format)
        for vname, block in VARIANTS:
            out = block(src)
            ne = [count(mask8([src, out], 'x y = 0 255 ?'), p) for p in range(3)]
            setdiff = count(mask8([src, out, o8, d8], 'x y = 1 0 ? z a = 1 0 ? = 0 255 ?'))
            dev = max(core.std.PlaneStats(core.std.Expr([out, up], 'x y - abs')).get_frame(i).props['PlaneStatsMax']
                      for i in range(src.num_frames)) / step
            left = removal(out, gt)
            if rng == 'limited':
                lost = count(mask8([src, out], f'x y - abs {step} % 0 = 0 255 ?'))
                lost_s = str(lost)
            else:
                lost_s = 'n/a (full range scales by 1023/255, not 4)'
            print(f'{fname} | {vname} | {ne[0] / total * 100:.3f} | '
                  f'{ne[1] / ctotal * 100:.3f}/{ne[2] / ctotal * 100:.3f} | '
                  f'{"yes" if setdiff == 0 else f"no ({setdiff} differ)"} | {dev:.2f} | {left:.3f} | {lost_s}')

        if name == 'gradient' and src.format.name == 'YUV422P10' and rng == 'limited':
            # Distinct luma values along one untouched row: banding is fewer of them.
            for label, c in [('source', src)] + [(v, b(src)) for v, b in VARIANTS]:
                print(f'  distinct values on row 288, x 0..719 ({label}): {len(set(row(c, 288, 0, W)))}')
            # Crops around the 2-px scratch at x=150 (the 1-px one at x=361 is too faint
            # for the plugin at its defaults, at any depth), luma stretched 16x
            # (64 10-bit levels = 16 8-bit levels -> 0..255).
            for label, c in [('1_source', src), ('2_current', old_block(src)), ('3_delta', new_block(src))]:
                c = core.std.CropAbs(c, 160, 120, 150 - 80, 240)
                s = core.std.Expr(core.std.ShufflePlanes(c, 0, vs.GRAY), 'x 256 - 4 *', format=vs.GRAY8)
                f = s.get_frame(0)
                with open(f'{img}/gradient_{label}.gray', 'wb') as fh:
                    for y in range(120):
                        fh.write(bytes(f[0][y, x] for x in range(160)))
        if name == 'capture' and src.format.name == 'YUV422P10' and rng == 'limited':
            # |output - source| around the 2-px scratch at x=150, x64, for each version.
            for label, b in [('4_diff_current', old_block), ('5_diff_delta', new_block)]:
                c = core.std.CropAbs(src, 160, 120, 150 - 80, 240)
                o = core.std.CropAbs(b(src), 160, 120, 150 - 80, 240)
                d = core.std.Expr([core.std.ShufflePlanes(c, 0, vs.GRAY), core.std.ShufflePlanes(o, 0, vs.GRAY)],
                                  'x y - abs 64 *', format=vs.GRAY8)
                f = d.get_frame(0)
                with open(f'{img}/capture_{label}.gray', 'wb') as fh:
                    for y in range(120):
                        fh.write(bytes(f[0][y, x] for x in range(160)))
