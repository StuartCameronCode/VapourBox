"""What converting a BT.601 picture to BT.709 does to saturated colours.

Run with scripts/run_vs.sh. For each patch (8-bit RGB), encodes it as BT.601
limited-range YUV (16-bit, so rounding does not muddy the comparison), then:

  matrixOnly  - converted 601 -> 709 matrix only (what VapourBox does), decoded as 709
  full        - matrix AND primaries converted (SMPTE C or EBU -> BT.709), decoded as 709
  misread     - the unconverted 601 samples decoded as 709: a player that
                ignores the tag on an HD picture

and prints each as 8-bit RGB next to the source decoded as 601.

Trap found doing this: VapourSynth R78's resizers let a frame's own _Matrix /
_Primaries properties override matrix_in_s / primaries_in_s, so every clip
here has those properties removed before the arguments are trusted. The first
run of this script did not, and printed "misread" equal to the source.
"""
import vapoursynth as vs

core = vs.core

PATCHES = {
    'red75': (191, 0, 0), 'green75': (0, 191, 0), 'blue75': (0, 0, 191),
    'yellow75': (191, 191, 0), 'cyan75': (0, 191, 191), 'magenta75': (191, 0, 191),
    'red100': (255, 0, 0), 'green100': (0, 255, 0), 'skin': (224, 172, 140),
    'grey': (128, 128, 128),
}


def clean(c):
    return core.std.RemoveFrameProps(c, ['_Matrix', '_Primaries', '_Transfer'])


def rgb_of(c):
    f = c.get_frame(0)
    return tuple(int(f[p][8, 8]) for p in range(3))


def decode(c, matrix):
    return rgb_of(core.resize.Point(clean(c), format=vs.RGB24, matrix_in_s=matrix, range_in_s='limited'))


def worst(a, b):
    return max(abs(x - y) for x, y in zip(a, b))


for prim in ('170m', '470bg'):
    print(f'source primaries {prim}')
    print(f'  {"patch":10s} {"source601":15s} {"matrixOnly":15s} {"full":15s} {"misread":15s}  worst: mOnly full misread')
    for name, rgb in PATCHES.items():
        patch = core.std.BlankClip(width=16, height=16, format=vs.RGB24, color=list(rgb), length=1)
        src = clean(core.resize.Point(patch, format=vs.YUV444P16, matrix_s='170m', range_s='limited'))
        m_only = core.resize.Spline36(src, format=vs.YUV444P16, matrix_in_s='170m', matrix_s='709',
                                      range_in_s='limited', range_s='limited')
        full = core.resize.Spline36(src, format=vs.YUV444P16, matrix_in_s='170m', matrix_s='709',
                                    primaries_in_s=prim, primaries_s='709',
                                    transfer_in_s='709', transfer_s='709',
                                    range_in_s='limited', range_s='limited')
        s601 = decode(src, '170m')
        mo, fu, mis = decode(m_only, '709'), decode(full, '709'), decode(src, '709')
        print(f'  {name:10s} {str(s601):15s} {str(mo):15s} {str(fu):15s} {str(mis):15s}'
              f'  {worst(mo, s601):5d} {worst(fu, s601):4d} {worst(mis, s601):7d}')
