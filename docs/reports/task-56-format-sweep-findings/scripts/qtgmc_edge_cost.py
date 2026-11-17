"""Task #56 F2: what padding a 4:2:x picture whose width is 2 mod 4 by two
columns (the QTGMC contract's width_step=CHROMA) does to QTGMC's output at
the presets that ran without it.

854x480 4:2:0 TFF, a synthetic moving picture (soft shapes, texture and
seeded noise that move by a few pixels a frame, made with akarin.Expr), QTGMC
at each preset, unpadded vs through plugin_formats.run_within(). Reported:
luma mean / max |difference| in 8-bit levels over the whole frame, over the
last 16 columns, and over everything left of them.

Run with the bundle's Python (PYTHONHOME / PYTHONPATH as reproduce.sh).
Limits: one synthetic clip, one machine (Apple Silicon); 8-bit only.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(HERE, '..', '..', '..', '..', 'worker', 'templates')))
import vapoursynth as vs  # noqa: E402
import havsfunc as haf  # noqa: E402
import plugin_formats as _pf  # noqa: E402

core = vs.core
W, H, FRAMES = 854, 480, 12


def picture():
    base = core.std.BlankClip(width=W, height=H, format=vs.GRAYS, length=FRAMES)
    expr = (f'X N 3 * + {W} / 0.6 * Y N 2 * + {H} / 0.3 * + '
            f'X N 3 * + 0.13 * sin Y 0.11 * sin * 0.08 * + '
            f'X 12.9898 * Y 78.233 * + N 3.17 * + sin 43758.5453 * dup floor - 0.5 - 0.05 * + 0 max 1 min')
    y = core.akarin.Expr(base, expr)
    c = core.resize.Bicubic(core.std.ShufflePlanes([y, y, y], [0, 0, 0], vs.YUV),
                            format=vs.YUV420P8, matrix_in_s='709', matrix_s='709')
    return core.std.SetFieldBased(c, 2)


def stats(a, b):
    d = core.akarin.Expr([core.std.ShufflePlanes(a, 0, vs.GRAY), core.std.ShufflePlanes(b, 0, vs.GRAY)],
                         'x y - abs', format=vs.GRAYS)
    out = []
    for crop in (None, ('right', W - 16), ('left', 16)):
        c = d if crop is None else core.std.Crop(d, **{('left' if crop[0] == 'right' else 'right'): crop[1]})
        s = core.std.PlaneStats(c)
        mean = mx = 0.0
        for n in range(s.num_frames):
            p = s.get_frame(n).props
            mean += p['PlaneStatsAverage']
            mx = max(mx, p['PlaneStatsMax'])
        out.append((mean / s.num_frames, mx))
    return out


def main():
    src = picture()
    print('# %dx%d 4:2:0 TFF, %d frames; luma |padded - unpadded| in 8-bit levels' % (W, H, FRAMES))
    print('preset        whole (mean/max)    last 16 cols (mean/max)   left of them (mean/max)')
    for preset in ('Placebo', 'Very Slow', 'Slower', 'Slow', 'Medium', 'Fast', 'Faster', 'Very Fast', 'Draft'):
        # (Super / Ultra Fast refuse this width unpadded: there is nothing to compare.)
        def q(c):
            return haf.QTGMC(c, Preset=preset, TFF=True)
        plain = q(src)
        # What the width step would do to this preset: the SrchClipPP-1
        # contract pads every preset's width here, which the template does
        # only for SrchClipPP 1 because of this table.
        padded = _pf.run_within(src, 'havsfunc.QTGMC[SrchClipPP=1]', q, delta_only=False)
        row = stats(plain, padded)
        print('%-12s  ' % preset + '   '.join('%6.3f / %6.1f      ' % r for r in row))
        sys.stdout.flush()


if __name__ == '__main__':
    main()
