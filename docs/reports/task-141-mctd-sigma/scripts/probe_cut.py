"""MCTemporalDenoise's thSCD1 at a real hard cut.

issue #177's `cut` fixture (probe_scd.py: 30 frames of one shot, a hard cut,
30 of another; clean, and with AddGrain sigma 6 and 9). Per frame, luma PSNR
against the clean cut fixture: the lowest of the six frames around the cut
(27-32) and the mean of the frames away from it. Ghosting across a missed
cut shows as a dip there that the default does not have.

Writes data/cut.json.
"""
import concurrent.futures as cf
import os

from mctdlib import run_mctd, save, scratch
from probe_scd import CUT, cut_fixture, psnr_per_frame


def one(c):
    sigma, prof, scd = c
    args = dict(settings=prof, sigma=4.0, radius=2)
    if scd:
        args['thSCD1'] = scd
    out = scratch('task141', f'cut_{sigma}_{prof.replace(" ", "")}_{scd}.mkv')
    run_mctd(cut_fixture(sigma), args, out)
    f = psnr_per_frame(out, cut_fixture(0))
    os.remove(out)
    near, away = f[CUT - 3:CUT + 3], f[3:CUT - 6] + f[CUT + 6:]
    return f'{sigma}|{prof}|{scd}', dict(frames=f, near_min=min(near), away_mean=sum(away) / len(away))


def main():
    res = {}
    cases = [(s, p, c) for s in [0, 6, 9] for p in ['low', 'medium', 'high', 'very high']
             for c in [None, 800, 1200, 2000, 4000]]
    with cf.ThreadPoolExecutor(int(os.environ.get('JOBS', '4'))) as ex:
        for k, v in ex.map(one, cases):
            res[k] = v
            print(k, round(v['near_min'], 2), round(v['away_mean'], 2), flush=True)
    save('cut.json', res)


if __name__ == '__main__':
    main()
