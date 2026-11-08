"""Noise-reduction comparison for the vszip upgrade (deps 1.16.0).

Methods, each at its best strength from a sweep (sweeps scale with the noise):
  - BM3D: the bm3d plugin r12 through the exact code of the NR_BM3D template
    block (16-bit, per GRAY plane, radius 1, Final step) - what ships today
  - NLMeans (vszip, CPU) and KNLMeansCL (GPU, the reference it ports)
  - WNNM (vszip), spatial and radius 1
  - BM3D (vszip, CPU, new in 24.0.0), radius 1 - for the record only

Each clean Kodak pan (make_fixtures.sh) gets AddGrain Gaussian noise of a known
sigma (8-bit levels, luma and chroma); PSNR (luma, then chroma U) against the
clean pan; fps from clip.frames() (VapourSynth's own parallel prefetch).

Run under the bundled interpreter with the deps environment, e.g.
  SCRATCH=... DEPS=deps/macos-arm64 scripts/run.sh nr_compare.py
Writes $SCRATCH/nr_results.json.
"""
import json
import math
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import vapoursynth as vs  # noqa: E402
from probelib import load, psnr, mad8, expr  # noqa: E402

core = vs.core
S = os.environ['SCRATCH']
FIXTURES = ['kodim08_pan', 'kodim19_pan', 'kodim23_pan']
NFR = int(os.environ.get('NFR', '10'))
SIGMAS = [float(x) for x in os.environ.get('SIGMAS', '4,8,12').split(',')]


def add_noise(c, sigma):
    return core.grain.Add(c, var=sigma * sigma, uvar=sigma * sigma, seed=7, constant=False)


def measured_sigma(noisy, clean):
    d = expr([core.std.ShufflePlanes(noisy, 0, vs.GRAY), core.std.ShufflePlanes(clean, 0, vs.GRAY)],
             'x y - dup *', vs.GRAYS)
    st = core.std.PlaneStats(d)
    return math.sqrt(sum(st.get_frame(i).props['PlaneStatsAverage'] for i in range(3)) / 3)


# --- methods (each returns a clip in the input's format) -------------------

def bm3d_template(c, sigma, radius=1, final=True, profile='np'):
    """Verbatim logic of the NR_BM3D block in worker/templates/*.vpy."""
    fmt = c.format

    def plane(p, s):
        if radius > 0:
            ref = core.bm3d.VAggregate(core.bm3d.VBasic(p, sigma=s, radius=radius, profile=profile), radius=radius)
            if final:
                ref = core.bm3d.VAggregate(core.bm3d.VFinal(p, ref, sigma=s, radius=radius, profile=profile),
                                           radius=radius)
            return ref
        ref = core.bm3d.Basic(p, sigma=s, profile=profile)
        return core.bm3d.Final(p, ref, sigma=s, profile=profile) if final else ref
    work = core.resize.Point(c, format=fmt.replace(bits_per_sample=16, sample_type=vs.INTEGER).id)
    planes = [core.std.ShufflePlanes(work, i, vs.GRAY) for i in range(fmt.num_planes)]
    planes = [plane(p, sigma) for p in planes]
    work = core.std.ShufflePlanes(planes, [0, 0, 0], fmt.color_family)
    return core.resize.Point(work, format=fmt.id, dither_type='error_diffusion')


def nlm_vszip(c, h, d=1, a=2, s=4):
    c = core.vszip.NLMeans(c, d=d, a=a, s=s, h=h, channels='Y')
    return core.vszip.NLMeans(c, d=d, a=a, s=s, h=h, channels='UV')


def nlm_knlm(c, h, d=1, a=2, s=4):
    c = core.knlm.KNLMeansCL(c, d=d, a=a, s=s, h=h, channels='Y', device_type='gpu')
    return core.knlm.KNLMeansCL(c, d=d, a=a, s=s, h=h, channels='UV', device_type='gpu')


def _to_float(c):
    # Default (limited) range both ways, so the round trip is exact (asserted
    # below). The float picture then spans 219 (luma) / 224 (chroma) 8-bit
    # levels per 1.0, so sigma (which WNNM divides by 255) is rescaled to stay
    # in 8-bit units. Passing range_in_s="full" instead is NOT safe: a clip
    # carrying _ColorRange=limited round-tripped 7 levels off at 10-bit.
    return core.resize.Point(c, format=c.format.replace(bits_per_sample=32, sample_type=vs.FLOAT).id)


def _from_float(f, fmt):
    return core.resize.Point(f, format=fmt.id, dither_type='error_diffusion')


def wnnm(c, sigma, radius=0):
    f = core.vszip.WNNM(_to_float(c), sigma=[sigma * 255 / 219, sigma * 255 / 224, sigma * 255 / 224],
                        radius=radius)
    return _from_float(f, c.format)


def bm3d_vszip(c, sigma, radius=1):
    f = core.vszip.BM3D(_to_float(c), sigma=[sigma * 255 / 219, sigma * 255 / 224, sigma * 255 / 224],
                        radius=radius)
    return _from_float(f, c.format)


MULT = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5]          # x noise sigma
NLM_H = [0.5, 0.75, 1.0, 1.5, 2.0, 2.75, 3.5, 4.5]   # x noise sigma / 4

METHODS = {
    'BM3D (bm3d r12, r=1, Final) - shipped': (bm3d_template, MULT),
    'NLMeans vszip CPU (d=1 a=2 s=4)': (nlm_vszip, None),
    'KNLMeansCL GPU (d=1 a=2 s=4)': (nlm_knlm, None),
    'WNNM vszip (r=0)': (lambda c, s: wnnm(c, s, 0), MULT),
    'WNNM vszip (r=1)': (lambda c, s: wnnm(c, s, 1), MULT),
    'BM3D vszip (r=1)': (bm3d_vszip, MULT),
}


def fps(clip):
    clip = core.std.Trim(clip, 0, NFR - 1)
    t = time.time()
    for _ in clip.frames(close=True):
        pass
    return NFR / (time.time() - t)


results = {'nfr': NFR, 'fixtures': {}}
# PARITY_ONLY=1 skips the (two-hour) sweep and runs only the depth checks.
for fx in ([] if os.environ.get('PARITY_ONLY') else FIXTURES):
    clean = load(os.path.join(S, 'fx', fx + '.mkv'), 'yuv420p', frames=NFR)
    results['fixtures'][fx] = {}
    for sigma in SIGMAS:
        noisy = add_noise(clean, sigma)
        row = {'measured_sigma': measured_sigma(noisy, clean), 'noisy_psnr_y': psnr(noisy, clean, 0),
               'methods': {}}
        print(f'\n== {fx} sigma {sigma} (measured {row["measured_sigma"]:.2f}); noisy Y {row["noisy_psnr_y"]:.2f} dB',
              flush=True)
        for name, (fn, mult) in METHODS.items():
            strengths = [round(m * sigma, 2) for m in mult] if mult else [round(k * sigma / 4, 2) for k in NLM_H]
            sweep = []
            for st in strengths:
                sweep.append((st, psnr(fn(noisy, st), clean, 0)))
            best = max(sweep, key=lambda r: r[1])
            out = fn(noisy, best[0])
            m = {'sweep': sweep, 'best_strength': best[0], 'psnr_y': best[1], 'psnr_u': psnr(out, clean, 1),
                 'fps': fps(fn(noisy, best[0]))}  # a fresh node: 'out' is cached
            edge = ' (edge of sweep)' if best[0] in (strengths[0], strengths[-1]) else ''
            print(f'  {name:40s} best {best[0]:>5}{edge:16s} Y {m["psnr_y"]:.2f}  U {m["psnr_u"]:.2f}  '
                  f'{m["fps"]:6.1f} fps', flush=True)
            row['methods'][name] = m
        results['fixtures'][fx][str(sigma)] = row
        # Written as it goes: a failure later must not lose the sweep.
        json.dump(results, open(os.path.join(S, 'nr_results.json'), 'w'), indent=1)

# --- depth parity: the same noisy picture at 8, 10 and 16 bits --------------
print('\n== depth parity: mean |8-bit run - N-bit run|, 8-bit levels (luma)', flush=True)
clean = load(os.path.join(S, 'fx', FIXTURES[0] + '.mkv'), 'yuv420p', frames=4)
noisy8 = add_noise(clean, 8)
results['float_round_trip'] = {}
for bits in (8, 10, 16):
    # How much of the WNNM row is the float conversion itself (it dithers).
    up = core.resize.Point(noisy8, format=noisy8.format.replace(bits_per_sample=bits).id)
    results['float_round_trip'][bits] = mad8(_from_float(_to_float(up), up.format), up, 0)
    print(f'  float round trip at {bits}-bit: {results["float_round_trip"][bits]:.4f} levels', flush=True)
results['parity'] = {}
for name, fn in [('NLMeans vszip h=2', lambda c: nlm_vszip(c, 2.0)),
                 ('WNNM sigma=8', lambda c: wnnm(c, 8.0)),
                 ('BM3D template sigma=8', lambda c: bm3d_template(c, 8.0))]:
    o8 = fn(noisy8)
    row = {}
    for bits in (10, 16):
        n = core.resize.Point(noisy8, format=noisy8.format.replace(bits_per_sample=bits).id)
        row[bits] = mad8(fn(n), o8, 0)
    results['parity'][name] = row
    print(f'  {name:28s} 10-bit {row[10]:.3f}  16-bit {row[16]:.3f}', flush=True)

o1 = nlm_vszip(noisy8, 2.0)
o2 = nlm_knlm(noisy8, 2.0)
results['nlm_vs_knlm_mad'] = {'y': mad8(o1, o2, 0), 'u': mad8(o1, o2, 1)}
print(f'\nvszip NLMeans vs KNLMeansCL, same args: mean |diff| Y {results["nlm_vs_knlm_mad"]["y"]:.4f} '
      f'U {results["nlm_vs_knlm_mad"]["u"]:.4f} levels')
json.dump(results, open(os.path.join(S, 'nr_parity.json' if os.environ.get('PARITY_ONLY') else
                                     'nr_results.json'), 'w'), indent=1)
