"""Section 2: how much scratch each way of running DeScratch removes.

    quality.py GT422 SC422 GT420 SC420 [IMG_DIR]

GT = the unscratched frames, SC = the same with drawn scratches (raw planar
8-bit, 720x576, 24 frames; reproduce.sh makes them). With IMG_DIR, writes the
luma crops the report shows as raw GRAY8 for reproduce.sh to turn into PNGs."""
import ctypes
import sys
import vapoursynth as vs
from common import core, load, native, carrier, progressive, per_field, mae, differing

gt422, sc422, gt420, sc420 = sys.argv[1:5]
img = sys.argv[5] if len(sys.argv) > 5 else None
STRIPS = [(144, 14), (354, 16), (554, 16)]


def report(name, out, clean_out=None):
    s = ' '.join(f'{mae(out, GT, x, w):6.3f}' for x, w in STRIPS)
    fp = f'{mae(clean_out, GT):.4f}' if clean_out is not None else '-'
    print(f'  {name:22s} strips {s}   full {mae(out, GT):.4f}   changes to clean clip {fp}')


def per_field_scaled(c):
    import math
    s = core.std.SeparateFields(c, tff=True)
    ang = math.degrees(math.atan(2 * math.tan(math.radians(5))))
    o = core.descratch.DeScratch(s, minlen=50, maxlen=1024, maxgap=1, blurlen=7, maxangle=ang)
    return core.std.DoubleWeave(o, tff=True)[::2]


print('== 4:2:2 (the plugin works field-aware here today), default parameters')
GT = core.std.SetFieldBased(load(gt422, vs.YUV422P8), 2)
SC = core.std.SetFieldBased(load(sc422, vs.YUV422P8), 2)
report('scratched input', SC)
report('field-aware (native)', native(SC), native(GT))
report('progressive', progressive(SC), progressive(GT))
report('per field', per_field(SC))
report('per field, rescaled', per_field_scaled(SC))

if img:
    crop = lambda c: core.std.ShufflePlanes(core.std.CropAbs(c, 160, 160, 100, 200), 0, vs.GRAY)[12]
    for name, clip in [('1_clean', GT), ('2_scratched', SC), ('3_field_aware', native(SC)),
                       ('4_progressive', progressive(SC)), ('5_per_field', per_field(SC))]:
        f = crop(clip).get_frame(0)
        base = ctypes.cast(f.get_read_ptr(0), ctypes.c_void_p).value
        with open(f'{img}/{name}.gray', 'wb') as fh:
            for row in range(160):
                fh.write(ctypes.string_at(base + row * f.get_stride(0), 160))

print('\n== 4:2:0, field-flagged')
GT = core.std.SetFieldBased(load(gt420, vs.YUV420P8), 2)
SC = core.std.SetFieldBased(load(sc420, vs.YUV420P8), 2)
for kw in [dict(), dict(blurlen=5), dict(blurlen=30), dict(mindif=3)]:
    print(' ', kw or 'defaults')
    for name, fn in [('native', native), ('carrier', carrier), ('progressive', progressive)]:
        try:
            report(name, fn(SC, **kw), fn(GT, **kw))
        except vs.Error as e:
            print(f'  {name:22s} FAILS: {str(e)[:60]}')
