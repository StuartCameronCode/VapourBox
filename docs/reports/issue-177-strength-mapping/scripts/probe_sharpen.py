"""Sharpen grid: every Sharpen method over a grid of its strength parameters,
on each progressive fixture softened by a Gaussian blur of sigma B px (and
unblurred, B 0, to see what sharpening a sharp picture costs).

Scores, per run: PSNR / SSIM against the unblurred original (how much of the
softening the setting undoes), the mean absolute luma change from its input
(how visible the effect is), and the worker's halo score of the output
(`--detect-noise-halo`, % of the step; the app's HALO_HIGH is 6.0).
Writes data/sharpen_runs.json (resumable).
"""
import concurrent.futures as cf
import itertools
import json
import os
import sys
import threading
import time

from build_fixtures import BLUR_SIGMAS, clean, soft
from probelib import DATA, compare, mean_abs_change, noise_halo, run_job, save, scratch, stream_info

BLURS = [0] + BLUR_SIGMAS
FIXTURES = ['cam', 'film', 'dvbt']


def grid():
    g = []
    lsf = list(itertools.product([50, 80, 100, 150, 200, 250, 300], [1, 2, 4, 8]))
    # 400 / 500 added after the first pass found the best at blur 1.6 at 300.
    lsf += list(itertools.product([400, 500], [2, 4, 8]))
    for st, os_ in lsf:
        g.append(('lsfmod', {'method': 'LSFmod', 'strength': st, 'overshoot': os_,
                             'undershoot': os_}))
    for s in [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 1.0]:
        g.append(('cas', {'method': 'CAS', 'casSharpness': s}))
    for d in [4, 8, 12, 16, 24, 32, 48, 64]:
        g.append(('awarpsharp2', {'method': 'AWarpSharp2', 'warpDepth': d}))
    return g


def key(method, params, fixture, blur):
    p = ','.join(f'{k}={v}' for k, v in sorted(params.items()) if k != 'method')
    return f'{method}|{p}|{fixture}|{blur}'


def main():
    path = os.path.join(DATA, 'sharpen_runs.json')
    runs = json.load(open(path)) if os.path.exists(path) else {}
    lock = threading.Lock()
    tasks = [(m, p, fx, b) for m, p in grid() for fx in FIXTURES for b in BLURS]
    tasks += [('input', {}, fx, b) for fx in FIXTURES for b in BLURS]
    tasks = [t for t in tasks if key(*t) not in runs]
    print(f'{len(tasks)} runs to do', flush=True)

    infos = {}

    def one(t):
        method, params, fx, b = t
        src = clean(fx) if b == 0 else soft(fx, b)
        if src not in infos:
            infos[src] = stream_info(src)
        info = infos[src]
        out = scratch('sh', f'{abs(hash(key(*t)))}.mkv')
        t0 = time.time()
        if method == 'input':
            target = src
        else:
            run_job(src, info, out, {'deinterlace': {'enabled': False},
                                     'sharpen': dict(enabled=True, **params)})
            target = out
        res = compare(target, clean(fx))
        res['secs'] = round(time.time() - t0, 2)
        res['change'] = round(mean_abs_change(target, src), 4)
        nh = noise_halo(target, info)
        res['halo'] = nh.get('halo')
        res['halo_edges'] = nh.get('haloEdges')
        if target == out:
            os.remove(out)
        with lock:
            runs[key(*t)] = {'method': method, 'params': params, 'fixture': fx, 'blur': b, **res}
            if len(runs) % 25 == 0:
                save('sharpen_runs.json', runs)
                print(len(runs), flush=True)

    with cf.ThreadPoolExecutor(int(os.environ.get('JOBS', '4'))) as ex:
        for f in cf.as_completed([ex.submit(one, t) for t in tasks]):
            if f.exception():
                print('FAILED', f.exception(), file=sys.stderr, flush=True)
    save('sharpen_runs.json', runs)


if __name__ == '__main__':
    main()
