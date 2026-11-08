"""Checks the three vs-jetpack ports and SangNom AA against their fixtures.

  vine_dehalo   - a clean Kodak pan oversharpened into halos (unsharp mask,
                  Gaussian sigma 1.5, amount 1.5); PSNR vs the clean pan for
                  vine and the existing Dehalo methods.
  mpeg2stinx    - the pans encoded as interlaced MPEG-2 (make_fixtures.sh);
                  PSNR vs the clean pan for mpeg2stinx and the existing
                  Deblock methods.
  FixInterlacedFades - a pan faded to black AFTER a field split: the top field
                  at the frame's fade level, the bottom field half a frame
                  later, as a fade applied to telecined video is. Residual
                  "combing" (mean |top - bottom| field brightness gap) and the
                  change it makes to ordinary, unfaded frames.
  depth parity  - each port at 10 and 16 bits against its 8-bit run.

The port functions are imported from the worker's own template (the block
between the markers named below is exec'd), so this measures the shipped code.

  SCRATCH=... ./run.sh ports_compare.py
"""
import json
import math
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import vapoursynth as vs  # noqa: E402
import havsfunc as haf  # noqa: E402
from probelib import load, psnr, mad8, expr  # noqa: E402

core = vs.core
S = os.environ['SCRATCH']
REPO = os.environ.get('REPO', os.path.abspath(os.path.join(HERE, '..', '..', '..', '..')))
TPL = open(os.path.join(REPO, 'worker', 'templates', 'pipeline_template.vpy')).read()


def template_block(name):
    """The Python between {{#NAME}} and {{/NAME}} in the shipped template."""
    m = re.search(r'\{\{#' + name + r'\}\}\n(.*?)\{\{/' + name + r'\}\}', TPL, re.S)
    return m.group(1)


# The helpers every template block relies on.
ns = {'vs': vs, 'core': core, 'haf': haf, 'math': math, 'functools': __import__('functools')}
exec(TPL[TPL.index('import platform as _platform'):TPL.index('# PASS 2: DEINTERLACING')].rsplit('# ====', 1)[0], ns)


def run_block(name, clip, subs):
    code = template_block(name)
    for k, v in subs.items():
        code = code.replace('{{' + k + '}}', str(v))
    code = re.sub(r'\{\{[#/][A-Z0-9_]+\}\}\n', '', code)
    env = dict(ns)
    env['clip'] = clip
    exec(code, env)
    return env['clip']


def fps(clip, n):
    clip = core.std.Trim(clip, 0, n - 1)
    t = time.time()
    for _ in clip.frames(close=True):
        pass
    return n / (time.time() - t)


NFR = int(os.environ.get('NFR', '10'))
out = {}

# ---- vine_dehalo ------------------------------------------------------------
def gauss(c, sigma):
    r = int(math.ceil(sigma * 3))
    k = [math.exp(-(x * x) / (2 * sigma * sigma)) for x in range(-r, r + 1)]
    return core.std.Convolution(core.std.Convolution(c, matrix=k, mode='h'), matrix=k, mode='v')


def vine(c, strength=16.0, sharp=0.5, sigma=1.0):
    return run_block('DEHALO_VINE', c, {'DEHALO_VINE_STRENGTH': strength, 'DEHALO_VINE_SHARP': sharp,
                                        'DEHALO_VINE_SIGMA': sigma})


out['vine'] = {}
for fx in ['kodim08_pan', 'kodim23_pan']:
    clean = load(os.path.join(S, 'fx', fx + '.mkv'), 'yuv420p', frames=NFR)
    halo = expr([clean, gauss(clean, 1.5)], 'x x y - 1.5 * +')
    rows = {'haloed (no filter)': halo,
            'vine (16, 0.5, 1.0)': vine(halo),
            'vine (24, 0.5, 1.0)': vine(halo, 24.0),
            'vine (8, 0.5, 1.0)': vine(halo, 8.0),
            'DeHalo_alpha (defaults)': haf.DeHalo_alpha(halo),
            'FineDehalo (defaults)': haf.FineDehalo(halo)}
    res = {name: {'psnr_y': psnr(c, clean, 0)} for name, c in rows.items()}
    # Speed on fresh nodes (the ones above are cached by the PSNR pass).
    res['vine (16, 0.5, 1.0)']['fps'] = fps(vine(halo), NFR)
    res['DeHalo_alpha (defaults)']['fps'] = fps(haf.DeHalo_alpha(halo), NFR)
    res['FineDehalo (defaults)']['fps'] = fps(haf.FineDehalo(halo), NFR)
    for name, r in res.items():
        print(f'vine {fx}: {name:28s} Y {r["psnr_y"]:.2f} dB  {r.get("fps", 0):.1f} fps', flush=True)
    out['vine'][fx] = res

# ---- mpeg2stinx ---------------------------------------------------------------
def stinx(c, tff=True):
    return run_block('DEBLOCK_MPEG2STINX', c, {'DEBLOCK_STINX_TFF': tff})


out['mpeg2stinx'] = {}


def ivtc(c):
    # As the IVTC method does it (VFM + VDecimate, defaults, TFF).
    return core.vivtc.VDecimate(core.vivtc.VFM(c, order=1))


def stinx_rows(enc, clean, label):
    rows = {'decoded (no filter)': enc,
            'mpeg2stinx (TFF)': stinx(enc),
            'mpeg2stinx (wrong order: BFF)': stinx(enc, False),
            'Deblock_QED (defaults)': haf.Deblock_QED(enc),
            'Deblock (quant 25)': core.deblock.Deblock(enc, quant=25)}
    res = {n: {'psnr_y': psnr(c, clean, 0), 'psnr_u': psnr(c, clean, 1)} for n, c in rows.items()}
    res['mpeg2stinx (TFF)']['fps'] = fps(stinx(enc), min(NFR, enc.num_frames))
    for n, r in res.items():
        print(f'mpeg2stinx {label}: {n:30s} Y {r["psnr_y"]:.2f}  U {r["psnr_u"]:.2f}', flush=True)
    return res


for fx in ['kodim08', 'kodim23']:
    clean24 = load(os.path.join(S, 'fx', fx + '_pan.mkv'), 'yuv420p', frames=24)
    for rate in (1000, 2000):
        # Hard-telecined, then inverse-telecined: what mpeg2stinx is for.
        enc = ivtc(load(os.path.join(S, 'fx', f'{fx}_tc_{rate}.mkv'), 'yuv420p', frames=30))
        assert enc.num_frames == 24, enc.num_frames
        # VDecimate must have kept the right frames: each matches its clean
        # frame far better than either neighbour.
        for i in (1, 12, 22):
            here = psnr(enc[i], clean24[i])
            assert here > psnr(enc[i], clean24[i - 1]) + 3 and here > psnr(enc[i], clean24[i + 1]) + 3, i
        out['mpeg2stinx'][f'{fx} telecined @{rate}k'] = stinx_rows(enc, clean24, f'{fx} telecined @{rate}k')
        # Progressive frames encoded as interlaced, no pulldown.
        clean = clean24[:NFR] if NFR <= 24 else clean24
        enc = load(os.path.join(S, 'fx', f'{fx}_mpeg2_{rate}.mkv'), 'yuv420p', frames=clean.num_frames)
        out['mpeg2stinx'][f'{fx} progressive-as-interlaced @{rate}k'] = stinx_rows(
            enc, clean, f'{fx} progressive-as-interlaced @{rate}k')

# ---- FixInterlacedFades -----------------------------------------------------
def fades(c, mode='average'):
    return run_block('DEINT_IVTC_FIX_FADES', c, {'IVTC_FADE_MODE': mode})


def field_gap(c):
    """Mean |top-field mean - bottom-field mean| of luma, 8-bit levels."""
    f = core.std.SeparateFields(core.std.SetFieldBased(c, 0), tff=True)
    st = core.std.PlaneStats(f)
    vals = [st.get_frame(i).props['PlaneStatsAverage'] for i in range(st.num_frames)]
    peak = (1 << c.format.bits_per_sample) - 1
    gaps = [abs(vals[2 * i] - vals[2 * i + 1]) * peak / (1 << (c.format.bits_per_sample - 8))
            for i in range(len(vals) // 2)]
    return sum(gaps) / len(gaps)


clean = load(os.path.join(S, 'fx', 'kodim23_pan.mkv'), 'yuv420p', frames=NFR)
n = clean.num_frames


def faded_after_split(c):
    """Fade to black over the clip, applied per field at field time."""
    flds = core.std.SeparateFields(core.std.SetFieldBased(c, 0), tff=True)
    total = 2 * n

    def lvl(k):
        return max(0.0, 1.0 - k / (total - 1))
    parts = []
    for k in range(total):
        a = lvl(k)
        # fade in the float domain about black (limited range: 16 -> 0.0)
        fl = core.resize.Point(flds[k], format=vs.YUV420PS)
        fl = expr([fl], [f'x {a} *', f'x {a} *', f'x {a} *'])
        parts.append(core.resize.Point(fl, format=c.format.id))
    return core.std.DoubleWeave(core.std.Splice(parts), tff=True)[::2]


def truth(c):
    """What a perfect fix gives: each frame at its two fields' mean level."""
    total = 2 * n
    parts = []
    for i in range(n):
        a = (max(0.0, 1.0 - (2 * i) / (total - 1)) + max(0.0, 1.0 - (2 * i + 1) / (total - 1))) / 2
        fl = core.resize.Point(c[i], format=vs.YUV420PS)
        parts.append(core.resize.Point(expr([fl], [f'x {a} *'] * 3), format=c.format.id))
    return core.std.Splice(parts)


faded = faded_after_split(clean)
gt = truth(clean)
fixed = fades(faded)
fixed_min = fades(faded, 'match')
out['fades'] = {
    'field_gap_faded': field_gap(faded), 'field_gap_fixed': field_gap(fixed),
    'field_gap_fixed_match': field_gap(fixed_min), 'field_gap_clean': field_gap(clean),
    'psnr_faded_vs_truth': psnr(faded, gt, 0), 'psnr_fixed_vs_truth': psnr(fixed, gt, 0),
    'unfaded_change_mad': mad8(fades(clean), clean, 0),
    'unfaded_change_mad_mpeg2': mad8(fades(load(os.path.join(S, 'fx', 'kodim08_mpeg2_1000.mkv'), 'yuv420p', frames=NFR)),
                                     load(os.path.join(S, 'fx', 'kodim08_mpeg2_1000.mkv'), 'yuv420p', frames=NFR), 0),
    'fps': fps(fades(faded), NFR),
}
print('fades:', json.dumps(out['fades'], indent=1), flush=True)

# ---- SangNom AA speed/effect -----------------------------------------------------
out['sangnom'] = {}
c = load(os.path.join(S, 'fx', 'kodim08_pan.mkv'), 'yuv420p', frames=NFR)
for name, f in [('daa', lambda x: haf.daa(core.std.SetFieldBased(x, 0))),
                ('santiag (nnedi3, 1/1)', lambda x: haf.santiag(core.std.SetFieldBased(x, 0))),
                ('SangNom AA (48)', lambda x: run_block('AA_SANGNOM', x, {'AA_SANGNOM_AA': 48, 'AA_FIELD_BASED_VALUE': 0}))]:
    out['sangnom'][name] = {'fps': fps(f(c), NFR), 'change_vs_src': mad8(f(c), c, 0)}
    print(f'AA {name:24s} {out["sangnom"][name]["fps"]:.1f} fps, mean change {out["sangnom"][name]["change_vs_src"]:.2f}',
          flush=True)

# ---- depth parity ---------------------------------------------------------------
out['parity'] = {}
base = load(os.path.join(S, 'fx', 'kodim08_mpeg2_1000.mkv'), 'yuv420p', frames=4)
halo8 = expr([base, gauss(base, 1.5)], 'x x y - 1.5 * +')
for name, f, src in [('vine', vine, halo8), ('mpeg2stinx', stinx, base), ('FixInterlacedFades', fades, faded[:4]),
                     ('SangNom AA', lambda x: run_block('AA_SANGNOM', x, {'AA_SANGNOM_AA': 48, 'AA_FIELD_BASED_VALUE': 0}),
                      base)]:
    o8 = f(src)
    row = {}
    for bits in (10, 16):
        up = core.resize.Point(src, format=src.format.replace(bits_per_sample=bits).id)
        row[bits] = mad8(f(up), o8, 0)
    out['parity'][name] = row
    print(f'parity {name:20s} 10-bit {row[10]:.3f}  16-bit {row[16]:.3f}', flush=True)

json.dump(out, open(os.path.join(S, 'ports_results.json'), 'w'), indent=1)
