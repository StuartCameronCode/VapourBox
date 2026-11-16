"""F7: Local Contrast (vszip.CLAHE) on genuinely deep content.

Compares the template's CLAHE as it was before task #56 (the limit scaled by
the measured content depth, 2 << (16 - depth), on a 16-bit histogram) with
the replacement (CLAHE on an 8-bit copy, only its change added at full
depth), against CLAHE on the 8-bit version of the same picture.

Run with the bundle's Python (see reproduce.sh). Pure VapourSynth: the test
picture is synthetic (a smooth shaded field with soft edges and seeded
pseudo-noise, made with akarin.Expr), so there is no input file.

Metric: luma mean and max |difference| from the 8-bit result, in 8-bit
levels, at strength 1 (the template's default strength 0.3 scales both by
0.3). The "passthrough" column is the same difference before any CLAHE:
what the deep picture differs from its 8-bit rounding anyway. The banding
check is the largest step between horizontally adjacent pixels on a smooth
ramp row, in 8-bit levels: the 8-bit result steps by whole levels; a deep
result should step by less.
"""
import argparse
import vapoursynth as vs

core = vs.core
LIMIT = 2


def picture(width, height, frames, noise):
    """A float picture in 0..1: soft shapes on a gradient, plus pseudo-noise
    (sigma ~ [noise] 8-bit levels) that changes per frame."""
    base = core.std.BlankClip(width=width, height=height, format=vs.GRAYS, length=frames)
    # gradient + soft discs + a fine texture; fract(sin()) hash as noise
    expr = (
        f'X {width} / 0.55 * Y {height} / 0.25 * + 0.1 + '
        f'X {width} 0.3 * - dup * Y {height} 0.5 * - dup * + sqrt {height} 0.25 * / 1 min 1 swap - 0.18 * + '
        f'X 0.21 * sin Y 0.17 * sin * 0.015 * + '
        f'X 12.9898 * Y 78.233 * + N 3.17 * + sin 43758.5453 * dup floor - 0.5 - {noise / 255 * 3.4} * + '
        '0 max 1 min'
    )
    return core.akarin.Expr(base, expr)


def quantise(c, bits):
    """[c] (float 0..1) as genuine [bits]-bit content in its natural container:
    8-bit in GRAY8, anything deeper in GRAY16 (low bits zero below 16)."""
    peak = (1 << bits) - 1
    if bits == 8:
        return core.akarin.Expr(c, f'x {peak} * round', format=vs.GRAY8)
    return core.akarin.Expr(c, f'x {peak} * round {1 << (16 - bits)} *', format=vs.GRAY16)


def clahe_before(y16, content_bits, tiles):
    """The template before task #56: the limit scaled by the content depth."""
    return core.vszip.CLAHE(y16, limit=LIMIT << (16 - content_bits), tiles=[tiles])


def clahe_after(y16, tiles, dither='none'):
    """Task #56: CLAHE on an 8-bit copy, only its change at full depth
    (plugin_formats.change_at). [dither] is the 8-bit copy's: 'none' rounds,
    so every sample of one 8-bit level gets the same change; a dither spreads
    a level's samples over its two neighbours in proportion, so the change
    between two levels' is interpolated on average."""
    work = core.resize.Bilinear(y16, format=vs.GRAY8, dither_type=dither)
    def back(c):
        return core.resize.Point(c, format=vs.GRAY16)
    return core.akarin.Expr([y16, back(core.vszip.CLAHE(work, limit=LIMIT, tiles=[tiles])), back(work)],
                            'x y + z -')


def levels(c):
    """In 8-bit levels, float."""
    peak = (1 << c.format.bits_per_sample) - 1
    return core.akarin.Expr(c, f'x {peak} / 255 *', format=vs.GRAYS)


def diff_stats(a, b):
    d = core.std.PlaneStats(core.akarin.Expr([levels(a), levels(b)], 'x y - abs'))
    mean = mx = 0.0
    for n in range(d.num_frames):
        p = d.get_frame(n).props
        mean += p['PlaneStatsAverage']
        mx = max(mx, p['PlaneStatsMax'])
    return mean / d.num_frames, mx


def max_step(c, blur=0):
    """Largest |x[1,0] - x| in 8-bit levels over the frame, after a
    horizontal box blur of radius [blur] (0: none). Unblurred it counts
    dither noise as steps; blurred, only a step wider than the blur
    (a band edge) survives."""
    c = levels(c)
    if blur:
        c = core.std.BoxBlur(c, hradius=blur, vradius=0)
    s = core.std.PlaneStats(core.akarin.Expr(c, 'x[1,0] x - abs'))
    return max(s.get_frame(n).props['PlaneStatsMax'] for n in range(s.num_frames))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--size', default='720x480')
    ap.add_argument('--tiles', type=int, default=8)
    ap.add_argument('--frames', type=int, default=4)
    ap.add_argument('--noise', type=float, default=6.0, help='noise sigma, 8-bit levels')
    a = ap.parse_args()
    w, h = (int(v) for v in a.size.split('x'))

    src = picture(w, h, a.frames, a.noise)
    y8 = quantise(src, 8)
    ref = core.vszip.CLAHE(y8, limit=LIMIT, tiles=[a.tiles])
    print(f'# {w}x{h}, {a.tiles} tiles, noise {a.noise}, limit {LIMIT}, strength 1')
    variants = [('rounded', 'none'), ('dithered', 'error_diffusion')]
    print('content            passthrough   before #56 (mean / max)   ' +
          '   '.join(f'{n} copy (mean / max)' for n, _ in variants))
    for bits in (10, 12, 14, 16):
        deep = quantise(src, bits)
        base, _ = diff_stats(deep, y8)
        row = [diff_stats(clahe_before(deep, bits, a.tiles), ref)]
        row += [diff_stats(clahe_after(deep, a.tiles, d), ref) for _, d in variants]
        print(f'{bits:2d}-bit genuine     {base:6.3f}        ' +
              '          '.join(f'{m:6.3f} / {x:5.1f}' for m, x in row))
    # 8-bit content in a 10- and 16-bit container: the content-depth case.
    for bits in (10, 16):
        boxed = core.resize.Point(y8, format=vs.GRAY16) if bits == 16 else \
            core.akarin.Expr(y8, 'x 4 * 64 *', format=vs.GRAY16)
        row = [diff_stats(clahe_before(boxed, 8, a.tiles), ref)]
        row += [diff_stats(clahe_after(boxed, a.tiles, d), ref) for _, d in variants]
        print(f' 8-bit in {bits:2d}-bit     {0:6.3f}        ' +
              '          '.join(f'{m:6.3f} / {x:5.1f}' for m, x in row))

    # Banding: a noiseless ramp, every row the same, 40 8-bit levels wide.
    ramp = core.akarin.Expr(core.std.BlankClip(width=w, height=h, format=vs.GRAYS, length=1),
                            f'0.3 X {w} / 40 255 / * +')
    print('\nbanding on a smooth ramp: largest step between neighbours, 8-bit levels,'
          ' raw / after a 13-px box blur')
    def show(name, c):
        print(f'{name:28s} {max_step(c):6.3f} / {max_step(c, 6):6.3f}')
    show(' 8-bit CLAHE', core.vszip.CLAHE(quantise(ramp, 8), limit=LIMIT, tiles=[a.tiles]))
    for bits in (10, 16):
        deep = quantise(ramp, bits)
        show(f'{bits:2d}-bit source itself', deep)
        show(f'{bits:2d}-bit before #56', clahe_before(deep, bits, a.tiles))
        for n, d in variants:
            show(f'{bits:2d}-bit after #56, {n}', clahe_after(deep, a.tiles, d))


if __name__ == '__main__':
    main()
