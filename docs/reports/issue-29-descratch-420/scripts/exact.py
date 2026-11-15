"""Section 3: the carrier against the native 4:2:0 call, sample for sample,
wherever the native call works; and the carrier at every height.

    exact.py SC420"""
import sys
import vapoursynth as vs
from common import core, load, native, carrier, differing

SC = load(sys.argv[1], vs.YUV420P8)
for fb in [0, 1, 2]:
    c = core.std.SetFieldBased(SC, fb)
    for kw in [dict(), dict(blurlen=5), dict(blurlen=30), dict(mindif=3)]:
        try:
            a = native(c, **kw)
            a.get_frame(0)
        except vs.Error:
            print(f'_FieldBased={fb} {kw or "defaults"}: native call fails, nothing to compare')
            continue
        b = carrier(c, **kw)
        d = [differing(a, b, p) for p in range(3)]
        print(f'_FieldBased={fb} {kw or "defaults"}: frames differing in Y/U/V: {d} of {a.num_frames};'
              f' carrier _FieldBased={b.get_frame(0).props.get("_FieldBased")}')

print('\ncarrier on field-flagged 4:2:0 BlankClips')
for h in [240, 288, 480, 486, 576, 1080]:
    for bl in [15, 30, 50]:
        c = core.std.SetFieldBased(core.std.BlankClip(width=720, height=h, format=vs.YUV420P8, length=1), 2)
        try:
            carrier(c, blurlen=bl).get_frame(0)
            r = 'ok'
        except vs.Error as e:
            r = 'FAILS: ' + str(e)[:50]
        print(h, bl, r)
