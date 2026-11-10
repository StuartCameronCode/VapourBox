"""Speed of each method, measured the way a job runs: vspipe, with the
graph's own parallelism, writing nowhere. One fresh vspipe per measurement
(so nothing is cached between methods), each run RUNS times, median kept.

  SCRATCH=... ./run.sh bench.py

Methods at the strengths nr_compare.py found best for sigma 8 on kodim08.
The source is the 640x480 Kodak pan (30 frames) with noise added, and the
same pan scaled to 1920x1080 (its first 10 frames) for an HD figure.
"""
import json
import os
import re
import statistics
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
S = os.environ['SCRATCH']
REPO = os.environ.get('REPO', os.path.abspath(os.path.join(HERE, '..', '..', '..', '..')))
RUNS = int(os.environ.get('RUNS', '3'))

PRELUDE = r'''
import os, sys
sys.path.insert(0, {here!r})
os.environ['SCRATCH'] = {scratch!r}
os.environ['REPO'] = {repo!r}
import vapoursynth as vs
core = vs.core
from probelib import load
src = load(os.path.join({scratch!r}, 'fx', 'kodim08_pan.mkv'), 'yuv420p', frames=30)
if {hd}:
    src = core.resize.Spline36(src[:10], 1920, 1080)  # 10 frames: BM3D runs ~0.1 fps at HD here
noisy = core.grain.Add(src, var=64, uvar=64, seed=7)
# the shipped template blocks, as ports_compare.py runs them
_pc = open(os.path.join({here!r}, 'ports_compare.py')).read()
_pc = _pc[:_pc.index('# ---- vine_dehalo')].replace('os.path.dirname(os.path.abspath(__file__))', repr({here!r}))
exec(_pc)
'''

NR = open(os.path.join(HERE, 'nr_compare.py')).read()
NR_FUNCS = NR[NR.index('def bm3d_template'):NR.index('MULT = ')]

METHODS = {
    'BM3D (bm3d r12, r=1, Final, sigma 16) - shipped': 'bm3d_template(noisy, 16.0)',
    'BM3D (bm3d r12, r=0, Final, sigma 16)': 'bm3d_template(noisy, 16.0, radius=0)',
    'NLMeans vszip CPU (d=1 a=2 s=4, h 7)': 'nlm_vszip(noisy, 7.0)',
    'KNLMeansCL GPU (d=1 a=2 s=4, h 7)': 'nlm_knlm(noisy, 7.0)',
    'WNNM vszip (r=0, sigma 16)': 'wnnm(noisy, 16.0, 0)',
    'WNNM vszip (r=1, sigma 16)': 'wnnm(noisy, 16.0, 1)',
    'BM3D vszip (r=1, sigma 10)': 'bm3d_vszip(noisy, 10.0)',
    'input only (decode + noise)': 'noisy',
    # The other new blocks, on the clean pan.
    'AA: daa': 'haf.daa(core.std.SetFieldBased(src, 0))',
    'AA: santiag (nnedi3, strength 1/1)': 'haf.santiag(core.std.SetFieldBased(src, 0))',
    'AA: SangNom (aa 48)': "run_block('AA_SANGNOM', src, {'AA_SANGNOM_AA': 48, 'AA_FIELD_BASED_VALUE': 0})",
    'Dehalo: DeHalo_alpha (defaults)': 'haf.DeHalo_alpha(src)',
    'Dehalo: vine (16, 0.5, 1.0)': "run_block('DEHALO_VINE', src, {'DEHALO_VINE_STRENGTH': 16.0, "
                                   "'DEHALO_VINE_SHARP': 0.5, 'DEHALO_VINE_SIGMA': 1.0})",
    'Deblock: Deblock_QED (defaults)': 'haf.Deblock_QED(src)',
    'Deblock: mpeg2stinx': "run_block('DEBLOCK_MPEG2STINX', src, {'DEBLOCK_STINX_TFF': True})",
    'IVTC fade fix (average), alone': "run_block('DEINT_IVTC_FIX_FADES', src, {'IVTC_FADE_MODE': 'average'})",
}


def vspipe_fps(body, hd):
    code = PRELUDE.format(here=HERE, scratch=S, repo=REPO, hd=hd) + NR_FUNCS + '\nclip = ' + body + '\nclip.set_output()\n'
    with tempfile.NamedTemporaryFile('w', suffix='.vpy', dir=S, delete=False) as f:
        f.write(code)
        path = f.name
    try:
        # Bounded: the first fade-fix block hung vspipe for 97 minutes here.
        r = subprocess.run(['vspipe', '-p', path, '--'], capture_output=True, text=True, timeout=900)
        m = re.search(r'Output (\d+) frames in ([\d.]+) seconds \(([\d.]+) fps\)', r.stderr)
        if not m:
            raise RuntimeError(r.stderr[-800:])
        return float(m.group(3))
    finally:
        os.unlink(path)


out = {}
for hd in (False, True):
    label = '1920x1080' if hd else '640x480'
    out[label] = {}
    for name, body in METHODS.items():
        runs = [vspipe_fps(body, hd) for _ in range(RUNS)]
        out[label][name] = {'median_fps': statistics.median(runs), 'runs': runs}
        print(f'{label} {name:50s} {statistics.median(runs):7.1f} fps  {runs}', flush=True)
json.dump(out, open(os.path.join(S, 'bench_results.json'), 'w'), indent=1)
