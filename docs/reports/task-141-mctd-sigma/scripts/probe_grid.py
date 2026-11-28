"""MCTemporalDenoise at every profile, and what could make Sigma act.

Per clip (cam, film, dvbt) and noise sigma (0 = clean, 2, 4, 6, 9), radius 2
(the app's default) and luma PSNR against the clean clip, frames 0-2 skipped:

  today     settings=<profile>, sigma=4.0 (the app's call before task #141)
  sigma     sigma 2 / 8 / 16: does Sigma act at all?
  post      post 2 / 4 / 6 / 8 (havsfunc's FFT3D pass after the denoise)
  pfMode 0  pfMode=0 with sigma 2 / 4 / 8 / 12 (FFT3D prefilter)
  thSCD1    800 / 1200 / 2000 (issue #177's fix for SMDegrain)
  thSAD     thSAD = thSAD2 = 600 / 1200
  limit 0   no cap at the prefilter's change

Writes data/grid.json (resumes: keys already there are not run again).
JOBS sets the parallel encodes (default 4).
"""
import concurrent.futures as cf
import os

from mctdlib import compare, fixture, key, load, run_mctd, save, scratch

PROFILES = ['very low', 'low', 'medium', 'high', 'very high']


def cases():
    for name in ['cam', 'film', 'dvbt']:
        for noise in [0, 2, 4, 6, 9]:
            base = dict(sigma=4.0, radius=2)
            for prof in PROFILES:
                yield name, noise, dict(base, settings=prof)
                for scd in [800, 1200, 2000]:
                    yield name, noise, dict(base, settings=prof, thSCD1=scd)
            for prof in ['low', 'medium', 'high']:
                for s in [2.0, 8.0, 16.0]:
                    yield name, noise, dict(base, settings=prof, sigma=s)
                for s in [2.0, 4.0, 8.0, 12.0]:
                    yield name, noise, dict(base, settings=prof, sigma=s, pfMode=0)
            for prof in ['low', 'medium', 'high', 'very high']:
                for p in [2.0, 4.0, 6.0, 8.0]:
                    yield name, noise, dict(base, settings=prof, post=p)
            for prof in ['low', 'medium']:
                for t in [600, 1200]:
                    yield name, noise, dict(base, settings=prof, thSAD=t, thSAD2=t)
                yield name, noise, dict(base, settings=prof, limit=0)


def one(c):
    name, noise, args = c
    k = key(name, noise, args)
    out = scratch('task141', k.replace('|', '_').replace(',', '_').replace('=', '-').replace(' ', '') + '.mkv')
    secs = run_mctd(fixture(name, noise), args, out)
    r = compare(out, fixture(name, 0), skip=3)
    os.remove(out)
    return k, dict(r, secs=secs)


def main():
    res = load('grid.json')
    todo = [c for c in cases() if key(*c) not in res]
    print(len(todo), 'runs', flush=True)
    with cf.ThreadPoolExecutor(int(os.environ.get('JOBS', '4'))) as ex:
        for i, (k, v) in enumerate(ex.map(one, todo)):
            res[k] = v
            print(i, k, round(v['psnr_y'], 2), flush=True)
            if i % 20 == 0:
                save('grid.json', res)
    save('grid.json', res)


if __name__ == '__main__':
    main()
