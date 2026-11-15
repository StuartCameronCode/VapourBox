"""gauss_blur.gaussian_blur against core.tcanny.TCanny(mode=-1): largest and
mean absolute difference over every plane, in the format's own units.

    compare.py <worker/templates> <frame.png>
"""
import sys

sys.path.insert(0, sys.argv[1])
import vapoursynth as vs
from gauss_blur import gaussian_blur

core = vs.core
rgb = core.vszip.ImageRead([sys.argv[2]])


def diff(a, b):
    worst = mean = 0
    d = core.std.Expr([a, b], 'x y - abs', format=a.format.replace(sample_type=vs.FLOAT, bits_per_sample=32))
    for p in range(a.format.num_planes):
        plane = core.std.ShufflePlanes(d, p, vs.GRAY)
        worst = max(worst, core.vszip.PlaneMinMax(plane).get_frame(0).props['psmMax'])
        mean = max(mean, core.std.PlaneStats(plane).get_frame(0).props['PlaneStatsAverage'])
    return worst, mean


# 0.537 / 0.849: MCDegrainSharp's default blur / sharpen sigma; 2: TemporalDegrain2's
# search-clip blur; 5: past std.Convolution's 25 taps (several passes), which no
# caller reaches (mClean clamps its sharp to 24, below the TCanny branch).
for fmt in (vs.YUV420P8, vs.YUV422P10, vs.YUV420P16, vs.GRAY8, vs.YUV444PS):
    clip = core.resize.Bicubic(rgb, format=fmt, matrix_s='709')
    for sigma, planes in ((0.537341772, [0, 1, 2]), (0.849, [0]), (0.849, [1, 2]), (2, [0, 1, 2]), (5.0, [0])):
        if clip.format.num_planes == 1 and planes != [0]:
            continue
        t = core.tcanny.TCanny(clip, sigma=sigma, mode=-1, planes=planes)
        g = gaussian_blur(clip, sigma, planes)
        worst, mean = diff(t, g)
        print(f"{clip.format.name:10s} sigma={sigma:<6.3g} planes={planes}: max |diff| {worst:.4g}, mean {mean:.3g}")
