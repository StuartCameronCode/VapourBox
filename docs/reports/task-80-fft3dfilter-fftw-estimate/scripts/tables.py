"""The report's tables, as HTML, from data/*.json (plain Python 3, no
VapourSynth). argv: none; prints each table under a comment naming it."""
import glob
import io
import json
import os
import statistics

DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'data')


def load(pattern):
    out = []
    for f in sorted(glob.glob(os.path.join(DATA, pattern))):
        out.append((os.path.basename(f), json.load(io.open(f, encoding='utf-8-sig'))))
    return out


def platform(name):
    for p in ('windows-x64', 'linux-x64', 'macos-x64', 'macos-arm64'):
        if p in name:
            return p
    return name


def cpu(d):
    p = d.get('processor') or ''
    return p.split(',')[0] if p and p not in ('arm', 'i386', 'x86_64') else '(%s)' % (p or '?')


def xproc_table(pattern, title):
    rows = load(pattern)
    print('<!-- %s -->' % title)
    print('<table><thead><tr><th>job</th><th>CPU</th><th>measure=0</th><th>measure=1</th>'
          '<th>default</th><th>0 after 1, one process</th></tr></thead><tbody>')
    for name, d in rows:
        x = d['xproc']
        n = len(x['0']['distinct'])

        def cell(m):
            bad = x[m]['keys_with_more_than_one']
            worst = max(x[m]['distinct'].values())
            return ('<td class="ok">%d/%d keys: 1 hash</td>' % (n, n) if not bad else
                    '<td class="bad">%d/%d keys: &gt;1 (up to %d)</td>' % (len(bad), n, worst))
        w = d.get('wisdom', {}).get('differs_from_fresh_0', [])
        print('<tr><td>%s</td><td>%s</td>%s%s%s<td>%s</td></tr>' % (
            name.replace('.json', ''), cpu(d), cell('0'), cell('1'), cell('default'),
            ', '.join(sorted({k.split()[0] for k in w})) + ' (%d keys)' % len(w) if w else 'none'))
    print('</tbody></table>')


def default_equals_zero(pattern):
    print('<!-- default vs measure=0 (%s) -->' % pattern)
    for name, d in load(pattern):
        x = d['xproc']
        same = all(list(x['default']['hashes'][k]) == list(x['0']['hashes'][k]) for k in x['0']['hashes'])
        print('%s: default == measure=0 on every key: %s' % (name, same))


def speed_table(pattern, title):
    rows = load(pattern)
    by = {}
    for name, d in rows:
        if 'speed' not in d:
            continue
        sp = d['speed']
        for k in sp['0']:
            if k in sp['1']:
                by.setdefault(platform(name), {}).setdefault(k, []).append(
                    100 * (sp['0'][k]['fps'] / sp['1'][k]['fps'] - 1))
    print('<!-- %s -->' % title)
    keys = sorted({k for p in by.values() for k in p})
    plats = [p for p in ('windows-x64', 'linux-x64', 'macos-x64', 'macos-arm64') if p in by]
    print('<table><thead><tr><th>call</th>%s</tr></thead><tbody>' % ''.join(
        '<th>%s (%d)</th>' % (p, len(next(iter(by[p].values())))) for p in plats))
    for k in keys:
        cells = []
        for p in plats:
            v = by[p].get(k)
            cells.append('<td>%s</td>' % ('%+.0f%% (%+.0f..%+.0f)' % (statistics.median(v), min(v), max(v)) if v else ''))
        print('<tr><td>%s</td>%s</tr>' % (k, ''.join(cells)))
    print('</tbody></table>')


def move_table(pattern, title):
    rows = [(n, d) for n, d in load(pattern) if 'move' in d]
    print('<!-- %s -->' % title)
    keys = sorted({k for _, d in rows for k in d['move']})
    print('<table><thead><tr><th>call, depth</th><th>jobs that moved</th><th>max (8-bit levels)</th>'
          '<th>samples changed</th><th>mean (8-bit levels)</th><th>min PSNR</th></tr></thead><tbody>')
    for k in keys:
        vs = [d['move'][k] for _, d in rows if k in d['move']]
        moved = [v for v in vs if v['pct_differ'] > 0]
        if not moved:
            print('<tr><td>%s</td><td>0/%d</td><td>0</td><td>0</td><td>0</td><td>identical</td></tr>' % (k, len(vs)))
            continue
        print('<tr><td>%s</td><td>%d/%d</td><td>%s</td><td>%.4f%%</td><td>%.5f</td><td>%.1f dB</td></tr>' % (
            k, len(moved), len(vs), max(v['max_abs_8bit'] for v in moved),
            max(v['pct_differ'] for v in moved), max(v['mean_abs_8bit'] for v in moved),
            min(v['psnr_db'] for v in moved)))
    print('</tbody></table>')


xproc_table('ci-rc1-run1-*.json', 'run 1, rc1: cross-process hashes')
xproc_table('ci-rc1-run2-*.json', 'run 2, rc1: cross-process hashes')
xproc_table('ci-rc2-run3-*.json', 'run 3, rc2 build: cross-process hashes')
xproc_table('ci-rc2-run4-*.json', 'run 4, rc2 build: cross-process hashes')
xproc_table('local-*-xproc.json', 'local M1 Pro, rc1')
default_equals_zero('ci-rc2-*.json')
speed_table('ci-rc*-run2-*.json', 'speed, run 2 (rc1)')
speed_table('ci-rc2-*.json', 'speed, runs 3 and 4 (rc2)')
speed_table('local-*-speed-move.json', 'speed, local M1 Pro')
move_table('ci-rc1-run2-*.json', 'move, run 2 (rc1), one draw per job')
move_table('ci-rc2-run3-*.json', 'move, run 3 (rc2), one draw per job')
move_table('ci-rc2-run4-*.json', 'move, run 4 (rc2), worst of 5 draws per job')
move_table('local-*-speed-move.json', 'move, local M1 Pro')
