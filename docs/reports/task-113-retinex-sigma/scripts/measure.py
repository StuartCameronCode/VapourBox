# Every Retinex number in the report, for the bundle this runs under (run.sh):
#   run.sh <deps> measure.py            -> JSON on stdout
# 1. plugin: core.retinex.name (the marker, or upstream's description).
# 2. synthetic: the push-gate test's picture (app/test/vapoursynth_integration_test.dart,
#    group "retinex sigma (task #113)"): average of MSRCP(sigma=[100]) and the
#    repeated-scale difference [100] vs [100, 100], at 8 and 16 bits.
# 3. frames: small_clip.mp4 frames (make_frames.sh, in $SCRATCH): mean and max
#    absolute difference between sigma=[X] and sigma=[25, 80, 250, X], which is
#    what r4 runs for sigma=[X] (its parser appends ours to the defaults;
#    nothing else differs between r4 and 6bfbdd42), at 8 and 10 bits.
# 4. reach: how far the Shadow Detail slider (sigma 1..500, default 100) moves
#    the picture under each parser.
# 5. hashes: MD5 of MSRCP's output on seeded grain, to compare two builds
#    byte for byte.
import ctypes, hashlib, json, os
import vapoursynth as vs
core = vs.core
SCRATCH = os.environ['SCRATCH']
out = {'plugin': core.retinex.name}

def msrcp(c, sigma):
    return core.retinex.MSRCP(c, sigma=sigma, lower_thr=0.001, upper_thr=0.001)

def diff(a, b):  # mean |a-b| in 8-bit levels
    return a.std.PlaneStats(b).get_frame(0).props['PlaneStatsDiff'] * 255

def maxdiff(a, b):
    peak = (1 << a.format.bits_per_sample) - 1
    return core.std.Expr([a, b], 'x y - abs').std.PlaneStats().get_frame(0).props['PlaneStatsMax'] * 255 / peak

def avg(c):
    return c.std.PlaneStats().get_frame(0).props['PlaneStatsAverage'] * 255

def gray8(W, H, rows):
    def draw(n, f):
        f = f.copy()
        ptr, stride = f.get_write_ptr(0).value, f.get_stride(0)
        for y, row in enumerate(rows):
            ctypes.memmove(ptr + y * stride, row, W)
        return f
    base = core.std.BlankClip(width=W, height=H, format=vs.GRAY8, length=1)
    return core.std.ModifyFrame(base, base, draw)

# 2. synthetic (same expression as the test)
W, H = 320, 240
pic8 = gray8(W, H, [bytes(min(255, 16 + 48 * x // W + (y % 7) * 3 + (x % 5) * 2 + 120 * x * y // (W * H))
                          for x in range(W)) for y in range(H)])
out['synthetic'] = {}
for depth, pic in (('8', pic8), ('16', core.resize.Point(pic8, format=vs.GRAY16))):
    one = msrcp(pic, [100])
    out['synthetic'][depth] = {
        'source_avg': round(avg(pic), 4),
        'sigma100_avg': round(avg(one), 4),
        'r4_equivalent_avg': round(avg(msrcp(pic, [25, 80, 250, 100])), 4),
        'repeated_scale_diff': round(diff(one, msrcp(pic, [100, 100])), 6),
    }

# 3/4. frames
frames = {}
for t in (3, 8, 14):
    p = os.path.join(SCRATCH, f'f{t}.gray')
    if os.path.exists(p):
        data = open(p, 'rb').read()
        frames[f'f{t}'] = gray8(720, 540, [data[y * 720:(y + 1) * 720] for y in range(540)])
out['frames'] = {}
out['reach'] = {}
for name, c8 in frames.items():
    for depth, c in (('8', c8), ('10', core.resize.Point(c8, format=vs.GRAY10))):
        for sigma in (100, 25, 250):
            fixed, r4 = msrcp(c, [sigma]), msrcp(c, [25, 80, 250, sigma])
            out['frames'][f'{name} {depth}-bit sigma {sigma}'] = {
                'mean': round(diff(fixed, r4), 3), 'max': round(maxdiff(fixed, r4), 1)}
    out['reach'][name] = {
        'fixed_1_500': round(diff(msrcp(c8, [1]), msrcp(c8, [500])), 2),
        'r4_1_500': round(diff(msrcp(c8, [25, 80, 250, 1]), msrcp(c8, [25, 80, 250, 500])), 2),
        'fixed_25_250': round(diff(msrcp(c8, [25]), msrcp(c8, [250])), 2),
        'r4_25_250': round(diff(msrcp(c8, [25, 80, 250, 25]), msrcp(c8, [25, 80, 250, 250])), 2),
    }

# 5. hashes
g = core.std.BlankClip(width=352, height=288, format=vs.GRAY8, length=6, color=[40])
g = core.grain.Add(g, var=200, seed=3, constant=False)
out['hashes'] = {}
for fmt in (vs.GRAY8, vs.GRAY16):
    for sig in ([100], [25], [500], [25, 80, 250]):
        m = hashlib.md5()
        for f in msrcp(core.resize.Point(g, format=fmt), sig).frames():
            m.update(bytes(f[0]))
        out['hashes'][f'{vs.PresetVideoFormat(fmt).name} {sig}'] = m.hexdigest()
print(json.dumps(out, indent=1))
