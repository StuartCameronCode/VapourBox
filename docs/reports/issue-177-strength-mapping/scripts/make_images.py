"""Crops for the report: each method's four Strength steps on one fixture.

Noise Reduction: `film` with sigma 6 noise (Strong's own level), frame 30.
Sharpen: `film` blurred by sigma 1.2 px (Strong's own level), frame 30.
Each panel is a 200x150 crop at 1:1, scaled 2x with nearest-neighbour so the
pixels are real. Writes img/<group>_<method>_<step>.png and the clean / input
panels; the report lays them out and labels them.
"""
import json
import os
import subprocess

from build_fixtures import clean, noisy, soft
from probelib import FFMPEG, REPORT, load, run_job, scratch, stream_info

IMG = os.path.join(REPORT, 'img')
FRAME = 30
CROP = 'crop=200:150:300:180'
RUST = {'smdegrain': 'smDegrain', 'mc_temporal_denoise': 'mcTemporalDenoise',
        'qtgmc_builtin': None, 'mclean': 'mClean',
        'lsfmod': 'LSFmod', 'cas': 'CAS', 'awarpsharp2': 'AWarpSharp2'}


def panel(src, name):
    out = os.path.join(IMG, f'{name}.png')
    subprocess.run([FFMPEG, '-y', '-v', 'error', '-i', src, '-vf',
                    f'select=eq(n\\,{FRAME}),{CROP},scale=iw*2:ih*2:flags=neighbor',
                    '-frames:v', '1', '-update', '1', out], check=True)
    return out


def main():
    os.makedirs(IMG, exist_ok=True)
    steps = load('steps.json')
    c = clean('film')
    panel(c, 'film_clean')
    n6 = noisy('film', 6)
    panel(n6, 'nr_input_n6')
    b12 = soft('film', 1.2)
    panel(b12, 'sh_input_b12')
    for group, src, key in [('noise_reduction', n6, 'noiseReduction'), ('sharpen', b12, 'sharpen')]:
        info = stream_info(src)
        for method, by in steps[group].items():
            if RUST[method] is None:
                continue  # QTGMC's denoiser needs an interlaced source; see the table
            for step, values in by.items():
                o = scratch('img', f'{method}_{step}.mkv')
                run_job(src, info, o, {'deinterlace': {'enabled': False},
                                       key: dict(enabled=True, method=RUST[method], **values)})
                panel(o, f"{'nr' if group == 'noise_reduction' else 'sh'}_{method}_{step.replace(' ', '_')}")
                os.remove(o)
                print(method, step, flush=True)


if __name__ == '__main__':
    main()
