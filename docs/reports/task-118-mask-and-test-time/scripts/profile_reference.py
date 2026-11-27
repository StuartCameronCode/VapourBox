# Profiles the 'havsfunc mask AND (patch 8)' test's script, part by part, with
# either reference. Same fixture, formats, calls and comparisons as the test.
#
#   REF=table  upstream's table as a Lut2 lut= list per call (before task #118)
#   REF=split  the 8-bit-table split reference (after)
#
# Run with the bundle's vspipe and havsfunc (macOS/Linux):
#   REF=split PYTHONPATH=$DEPS/python-packages $DEPS/vapoursynth/vspipe -i profile_reference.py -
# Timings go to stderr.
import collections
import os
import sys
import time
T0 = time.perf_counter()
import vapoursynth as vs
import havsfunc as haf
core = vs.core

MODE = os.environ.get('REF', 'split')
acc = collections.Counter()
cnt = collections.Counter()
patched = haf._mask_and
AND8 = [x & y for y in range(256) for x in range(256)]
SPLIT = {}


def table(a, b):
    ba, bb = a.format.bits_per_sample, b.format.bits_per_sample
    t = time.perf_counter()
    lut = [x & y for y in range(1 << bb) for x in range(1 << ba)]
    acc['reference: build list, %d-bit' % ba] += time.perf_counter() - t
    t = time.perf_counter()
    r = core.std.Lut2(a, b, lut=lut)
    acc['reference: Lut2 creation, %d-bit' % ba] += time.perf_counter() - t
    return r


def split(a, b):
    bits = a.format.bits_per_sample
    assert b.format.bits_per_sample == bits
    if bits == 8:
        return core.std.Lut2(a, b, lut=AND8)
    if bits not in SPLIT:
        s, m = bits - 8, (1 << (bits - 8)) - 1
        SPLIT[bits] = ([v >> s for v in range(1 << bits)], [v & m for v in range(1 << bits)],
                       [(x << s) | y for y in range(256) for x in range(256)])
    hi, lo, join = SPLIT[bits]
    h = core.std.Lut2(core.std.Lut(a, lut=hi, bits=8), core.std.Lut(b, lut=hi, bits=8), lut=AND8)
    l = core.std.Lut2(core.std.Lut(a, lut=lo, bits=8), core.std.Lut(b, lut=lo, bits=8), lut=AND8)
    return core.std.Lut2(h, l, lut=join, bits=bits)


def reference(a, b):
    bits = a.format.bits_per_sample
    cnt['reference calls, %d-bit' % bits] += 1
    if MODE == 'table':
        return table(a, b)
    t = time.perf_counter()
    r = split(a, b)
    acc['reference: split, %d-bit' % bits] += time.perf_counter() - t
    return r


def fixture(fmt):
    f = core.get_video_format(fmt)
    mid = 1 << (f.bits_per_sample - 1)
    c = core.std.BlankClip(width=160, height=120, format=fmt, length=6, color=[mid] * 3)
    g = core.grain.Add(c, var=40, uvar=40, constant=False, seed=3)
    return core.std.StackVertical([g.std.Crop(bottom=40), c.std.Crop(top=80)])


def same(a, b):
    for p in range(a.format.num_planes):
        st = core.std.PlaneStats(a, b, plane=p)
        for n in range(a.num_frames):
            if st.get_frame(n).props['PlaneStatsDiff'] != 0:
                return False
    return True


CALLS = {
    'LUTDeCrawl': lambda c, m: haf.LUTDeCrawl(c, ythresh=10, cthresh=10, maxdiff=50, mask=m),
    'LUTDeRainbow': lambda c, m: haf.LUTDeRainbow(c, cthresh=10, ythresh=10, y=True, linkUV=True, mask=m),
    'LUTDeRainbow unlinked': lambda c, m: haf.LUTDeRainbow(c, cthresh=10, ythresh=10, y=True, linkUV=False, mask=m),
}
for fmt in (vs.YUV420P8, vs.YUV422P8, vs.YUV444P8, vs.YUV420P10, vs.YUV422P10, vs.YUV444P10):
    clip = fixture(fmt)
    for label, call in CALLS.items():
        for mask in ((False, True) if fmt in (vs.YUV420P8, vs.YUV420P10, vs.YUV422P8, vs.YUV444P8) else (False,)):
            haf._mask_and = patched
            t = time.perf_counter()
            got = call(clip, mask)
            acc['patched calls'] += time.perf_counter() - t
            haf._mask_and = reference
            want = call(clip, mask)
            haf._mask_and = patched
            t = time.perf_counter()
            assert same(got, want), (fmt, label, mask)
            acc['comparisons (same)'] += time.perf_counter() - t
print('REF=%s' % MODE, file=sys.stderr)
for k in sorted(acc):
    print('%-36s %7.2f s' % (k, acc[k]), file=sys.stderr)
for k in sorted(cnt):
    print('%-36s %7d' % (k, cnt[k]), file=sys.stderr)
print('%-36s %7.2f s' % ('whole script', time.perf_counter() - T0), file=sys.stderr)
core.std.BlankClip().set_output()
