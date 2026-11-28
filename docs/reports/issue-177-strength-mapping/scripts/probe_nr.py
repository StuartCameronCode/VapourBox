"""Noise Reduction grid: every simple-mode method over a grid of its strength
parameters, on every fixture at every noise level (and clean, sigma 0).

Each run is a worker encode to lossless FFV1; the score is PSNR / SSIM of the
output against the clean source. Writes data/nr_runs.json (resumable: runs
already in it are skipped).

QTGMC's built-in denoiser needs deinterlacing on, so it runs on the
interlaced `vhs` fixture only, and its reference is the clean source through
the same QTGMC with no denoising (EZDenoise 0), not the source itself.
"""
import concurrent.futures as cf
import itertools
import json
import os
import sys
import threading
import time

from build_fixtures import NOISE_SIGMAS, clean, noisy
from probelib import DATA, compare, run_job, save, scratch, stream_info

SIGMAS = [0] + NOISE_SIGMAS
PROGRESSIVE = ['cam', 'film', 'dvbt']
QTGMC = {'enabled': True, 'tff': True}


def grid():
    g = []
    # thSAD above 1200 and tr 4 were added after the first pass showed SMDegrain
    # doing nothing at sigma 9 with any thSAD up to 1200 (each block's SAD of
    # that much noise is over the threshold, so no match is used).
    sm = list(itertools.product([1, 2, 3], [150, 200, 300, 400, 600, 800, 1000, 1200,
                                            1500, 2000, 2500, 3000, 4000]))
    sm += list(itertools.product([4], [800, 1200, 2000, 3000, 4000]))
    for tr, th in sm:
        g.append(('smdegrain', {'method': 'smDegrain', 'smDegrainTr': tr, 'smDegrainThSAD': th,
                                'smDegrainThSADC': th // 2}))
    # Then the scene-change threshold (thSCD1, havsfunc's default 400), once
    # sigma 9 turned out to be every frame a "cut" at 400 (probe_scd.py).
    for tr, th, scd in itertools.product([2, 3], [400, 600, 800, 1200, 2000], [800, 1200]):
        g.append(('smdegrain', {'method': 'smDegrain', 'smDegrainTr': tr, 'smDegrainThSAD': th,
                                'smDegrainThSADC': th // 2, 'smDegrainThSCD1': scd}))
    # MCTD: every profile x sigma at its default radius 2, and radius 1 / 3 at
    # the medium profile (the grid was cut down from a full product for time).
    mctd = list(itertools.product(['low', 'medium', 'high'], [2.0, 4.0, 6.0, 8.0, 12.0], [2]))
    mctd += list(itertools.product(['medium'], [4.0, 8.0, 12.0], [1, 3]))
    # Sigma turned out to be inert at every profile (havsfunc uses it only for
    # pfMode 0 or post > 0, neither of which VapourBox passes): the rest of the
    # profiles and radii at the default sigma only.
    mctd += [('very low', 4.0, 2), ('very high', 4.0, 2), ('very high', 4.0, 3),
             ('high', 4.0, 1), ('high', 4.0, 3), ('low', 4.0, 1), ('low', 4.0, 3),
             ('very high', 4.0, 4), ('high', 4.0, 4)]
    for prof, sig, rad in mctd:
        g.append(('mc_temporal_denoise', {'method': 'mcTemporalDenoise', 'mcTemporalProfile': prof,
                                          'mcTemporalSigma': sig, 'mcTemporalRadius': rad}))
    # mClean: its default sharp (10); rn (grain put back) at 0 and its default 14.
    for st, th, rn in itertools.product([5, 10, 15, 20], [200, 400, 900, 1500, 2500], [0, 14]):
        g.append(('mclean', {'method': 'mClean', 'mcleanStrength': st, 'mcleanThsad': th,
                             'mcleanRn': rn}))
    return g


QTGMC_GRID = [('qtgmc_builtin', {'method': 'qtgmcBuiltin', 'qtgmcEzDenoise': ez,
                                 'qtgmcEzKeepGrain': 0.0})
              for ez in [0.5, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0]]


def key(method, params, fixture, sigma):
    p = ','.join(f'{k}={v}' for k, v in sorted(params.items()) if k != 'method')
    return f'{method}|{p}|{fixture}|{sigma}'


def main():
    path = os.path.join(DATA, 'nr_runs.json')
    runs = json.load(open(path)) if os.path.exists(path) else {}
    lock = threading.Lock()

    # QTGMC references: the clean vhs source deinterlaced, no denoising.
    vclean = clean('vhs')
    vinfo = stream_info(vclean)
    qref = scratch('nr', 'vhs_qtgmc_ref.mkv')
    if not os.path.exists(qref):
        run_job(vclean, vinfo, qref, {'deinterlace': QTGMC}, field_order='tff')

    tasks = []
    for method, params in grid():
        for fx in PROGRESSIVE:
            for s in SIGMAS:
                tasks.append((method, params, fx, s))
    for method, params in QTGMC_GRID:
        for s in SIGMAS:
            tasks.append((method, params, 'vhs', s))
    # The input itself, per fixture and level, so a gain can be stated.
    tasks += [('input', {}, fx, s) for fx in PROGRESSIVE for s in SIGMAS]
    tasks += [('input', {}, 'vhs', s) for s in SIGMAS]
    tasks = [t for t in tasks if key(*t) not in runs]
    print(f'{len(tasks)} runs to do', flush=True)

    infos = {}

    def one(t):
        method, params, fx, s = t
        src = clean(fx) if s == 0 else noisy(fx, s)
        if src not in infos:
            infos[src] = stream_info(src)
        info = infos[src]
        is_q = fx == 'vhs'
        ref = qref if is_q else clean(fx)
        out = scratch('nr', f'{abs(hash(key(*t)))}.mkv')
        t0 = time.time()
        if method == 'input' and not is_q:
            res = compare(src, ref)
            secs = 0.0
        else:
            pipe = {'deinterlace': QTGMC if is_q else {'enabled': False}}
            if method != 'input':
                pipe['noiseReduction'] = dict(enabled=True, **params)
            run_job(src, info, out, pipe, field_order='tff' if is_q else None)
            secs = time.time() - t0
            res = compare(out, ref)
            os.remove(out)
        res['secs'] = round(secs, 2)
        res['frames'] = info['frames']
        with lock:
            runs[key(*t)] = {'method': method, 'params': params, 'fixture': fx, 'sigma': s, **res}
            if len(runs) % 25 == 0:
                save('nr_runs.json', runs)
                print(len(runs), flush=True)

    with cf.ThreadPoolExecutor(int(os.environ.get('JOBS', '4'))) as ex:
        for f in cf.as_completed([ex.submit(one, t) for t in tasks]):
            if f.exception():
                print('FAILED', f.exception(), file=sys.stderr, flush=True)
    save('nr_runs.json', runs)


if __name__ == '__main__':
    main()
