"""Render the report's tables from data/grid.json and data/cut.json.

Prints HTML <table> fragments, one per section, each headed by a marker
comment (<!-- table:NAME -->); make_report.py splices them into index.html.
"""
import json
import os

from mctdlib import DATA, key

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, '..', '..', 'issue-177-strength-mapping', 'data', 'fixtures.json')
CLIPS = ['cam', 'film', 'dvbt']
NOISES = [0, 2, 4, 6, 9]
PROFILES = ['very low', 'low', 'medium', 'high', 'very high']

g = json.load(open(os.path.join(DATA, 'grid.json')))
fx = json.load(open(FIXTURES))


def v(name, noise, field='psnr_y', **a):
    args = dict(sigma=4.0, radius=2)
    args.update(a)
    return g[key(name, noise, args)][field]


def inp(name, noise):
    return 99.0 if noise == 0 else fx[name]['noisy'][str(noise)]['psnr_y']


def table(head, rows, cls=None):
    out = ['<table>', '<tr>' + ''.join(f'<th>{h}</th>' for h in head) + '</tr>']
    for r in rows:
        tr = '<tr class="input">' if cls and cls(r) else '<tr>'
        out.append(tr + ''.join(f'<td>{c}</td>' for c in r) + '</tr>')
    out.append('</table>')
    return '\n'.join(out)


def f2(x):
    return 'clean' if x >= 99 else f'{x:.2f}'


def sigma_inert():
    rows, worst = [], 0.0
    for n in CLIPS:
        for s in NOISES:
            for p in ['low', 'medium', 'high']:
                vals = [v(n, s, settings=p, sigma=x) for x in [2.0, 4.0, 8.0, 16.0]]
                spread = max(vals) - min(vals)
                worst = max(worst, spread)
            rows.append([n, s] + [f2(v(n, s, settings=p)) for p in ['low', 'medium', 'high']])
    return table(['clip', 'noise σ', 'low', 'medium', 'high'], rows) + \
        f'\n<p class="cap">Largest spread between sigma 2, 4, 8 and 16 in any of these 45 cells: ' \
        f'<b>{worst:.4f} dB</b>.</p>'


def post():
    rows = []
    for n in CLIPS:
        for s in NOISES:
            for p in ['medium', 'high', 'very high']:
                rows.append([n, s, f2(inp(n, s)), p, f2(v(n, s, settings=p))] +
                            [f2(v(n, s, settings=p, post=x)) for x in [2.0, 4.0, 6.0, 8.0]])
    return table(['clip', 'noise σ', 'input', 'profile', 'post 0 (today)', 'post 2', 'post 4', 'post 6', 'post 8'], rows)


def pf0():
    rows = []
    for n in CLIPS:
        for s in NOISES:
            rows.append([n, s, f2(v(n, s, settings='medium'))] +
                        [f2(v(n, s, settings='medium', pfMode=0, sigma=x)) for x in [2.0, 4.0, 8.0, 12.0]] +
                        [f2(v(n, s, settings='medium', post=x)) for x in [4.0, 8.0]])
    return table(['clip', 'noise σ', 'today', 'pfMode 0 σ2', 'σ4', 'σ8', 'σ12', 'post 4', 'post 8'], rows)


def heavy():
    rows = []
    for n in CLIPS:
        for s in [0, 6, 9]:
            for p in ['low', 'medium']:
                rows.append([n, s, f2(inp(n, s)), p, f2(v(n, s, settings=p))] +
                            [f2(v(n, s, settings=p, thSCD1=c)) for c in [800, 1200, 2000]] +
                            [f2(v(n, s, settings=p, thSAD=t, thSAD2=t)) for t in [600, 1200]] +
                            [f2(v(n, s, settings=p, limit=0))] +
                            [f2(v(n, s, settings=p, post=8.0))])
    return table(['clip', 'noise σ', 'input', 'profile', 'today', 'thSCD1 800', '1200', '2000',
                  'thSAD 600', '1200', 'limit 0', 'post 8'], rows)


def strength_steps():
    rows = []
    hint = {'high': 4, 'very high': 6}
    for p, s in hint.items():
        for n in CLIPS:
            for noise in [0, s]:
                rows.append([p, n, noise, f2(v(n, noise, settings=p))] +
                            [f2(v(n, noise, settings=p, post=x)) for x in [2.0, 4.0]])
    return table(['profile (step)', 'clip', 'noise σ', 'today', 'post 2', 'post 4'], rows)


def timing():
    rows = []
    for n in CLIPS:
        for p in ['medium', 'high', 'very high']:
            t0 = sum(v(n, s, 'secs', settings=p) for s in NOISES) / len(NOISES)
            t4 = sum(v(n, s, 'secs', settings=p, post=4.0) for s in NOISES) / len(NOISES)
            rows.append([n, p, f'{t0:.1f}', f'{t4:.1f}', f'{t4 / t0:.2f}x'])
    return table(['clip', 'profile', 'post 0 (s)', 'post 4 (s)', 'ratio'], rows)


def cut():
    c = json.load(open(os.path.join(DATA, 'cut.json')))
    rows = []
    for s in [0, 6, 9]:
        for p in ['low', 'medium', 'high', 'very high']:
            r = [s, p]
            for scd in ['None', '800', '1200', '2000', '4000']:
                e = c[f'{s}|{p}|{scd}']
                r.append(f"{e['near_min']:.2f} / {e['away_mean']:.2f}")
            rows.append(r)
    return table(['noise σ', 'profile', 'default thSCD1', '800', '1200', '2000', '4000'], rows)


SECTIONS = dict(sigma=sigma_inert, post=post, pf0=pf0, heavy=heavy, steps=strength_steps,
                timing=timing, cut=cut)

if __name__ == '__main__':
    for name, fn in SECTIONS.items():
        print(f'<!-- table:{name} -->')
        print(fn())
