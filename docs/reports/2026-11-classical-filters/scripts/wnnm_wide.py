"""WNNM's best sigma sometimes sat at the top of nr_compare.py's sweep (2.5x
the noise). This widens it to 4x for WNNM only, on every fixture and sigma,
so the comparison with BM3D is not cut short.

  SCRATCH=... ./run.sh wnnm_wide.py      -> $SCRATCH/wnnm_wide.json
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
src = open(os.path.join(HERE, 'nr_compare.py')).read()
exec(src[:src.index('results = {')])

out = {}
for fx in FIXTURES:
    clean = load(os.path.join(S, 'fx', fx + '.mkv'), 'yuv420p', frames=NFR)
    out[fx] = {}
    for sigma in SIGMAS:
        noisy = add_noise(clean, sigma)
        out[fx][str(sigma)] = {}
        for r in (0, 1):
            sweep = [(m * sigma, psnr(wnnm(noisy, m * sigma, r), clean, 0)) for m in (2.0, 2.5, 3.0, 3.5, 4.0)]
            best = max(sweep, key=lambda t: t[1])
            out[fx][str(sigma)][f'r={r}'] = {'sweep': sweep, 'best': best,
                                             'psnr_u': psnr(wnnm(noisy, best[0], r), clean, 1)}
            print(f'{fx} sigma {sigma} WNNM r={r}: best {best[0]:g} -> Y {best[1]:.2f}  '
                  f'U {out[fx][str(sigma)][f"r={r}"]["psnr_u"]:.2f}  sweep {[(s, round(p, 2)) for s, p in sweep]}',
                  flush=True)
json.dump(out, open(os.path.join(S, 'wnnm_wide.json'), 'w'), indent=1)
