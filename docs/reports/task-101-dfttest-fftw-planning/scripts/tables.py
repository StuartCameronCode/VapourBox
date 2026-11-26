"""Prints the report's tables (HTML fragments) from data/: one row per
machine for the cross-process probe (PATIENT and ESTIMATE), the worst split,
the wisdom check, the ESTIMATE-vs-PATIENT movement and speed.
Local runs: data/<kind>-macos-<arch>[-rosetta][-<build>].json(l).
CI runs: data/ci/<run>/<job>/{probe,wisdom}-{patient,estimate}.json,
move.json, speed.jsonl.
argv: [data dir]"""
import glob
import json
import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
D = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, '..', 'data')


def load(p):
    with open(p, encoding='utf-8-sig') as fh:
        return json.load(fh)


def speed(p):
    runs = {}
    with open(p, encoding='utf-8-sig') as fh:
        for line in fh:
            if line.strip():
                j = json.loads(line)
                runs.setdefault(j['build'], []).append(j['result']['speed'])
    return runs


machines = []  # (label, patient probe, estimate probe, wisdom p, wisdom e, move, speed)
for arch, label in (('arm64', 'macOS arm64, M1 (local)'), ('x64-rosetta', 'macOS x64 under Rosetta, M1 (local)')):
    a = arch.replace('-rosetta', '')
    sfx = '-rosetta' if 'rosetta' in arch else ''
    machines.append((label,
                     os.path.join(D, 'probe-macos-%s%s.json' % (a, sfx)),
                     os.path.join(D, 'probe-macos-%s-est%s.json' % (a, sfx)),
                     os.path.join(D, 'wisdom-macos-%s-patient.json' % arch),
                     os.path.join(D, 'wisdom-macos-%s-estimate.json' % arch),
                     os.path.join(D, 'move-macos-%s.json' % arch),
                     os.path.join(D, 'speed-macos-%s.jsonl' % arch)))
for job in sorted(glob.glob(os.path.join(D, 'ci', '*', '*'))):
    run, name = job.split(os.sep)[-2:]
    cpu = ''
    if os.path.exists(os.path.join(job, 'cpu.txt')):
        with open(os.path.join(job, 'cpu.txt'), encoding='utf-8-sig') as fh:
            cpu = ', ' + fh.read().strip()
    machines.append(('%s (CI run %s%s)' % (name, run, cpu),
                     os.path.join(job, 'probe-patient.json'), os.path.join(job, 'probe-estimate.json'),
                     os.path.join(job, 'wisdom-patient.json'), os.path.join(job, 'wisdom-estimate.json'),
                     os.path.join(job, 'move.json'), os.path.join(job, 'speed.jsonl')))

print('<h3>Cross-process probe</h3>\n<table><tr><th>Machine</th><th>Processes</th>'
      '<th>PATIENT: keys with &gt; 1 picture</th><th>Most pictures for one key</th>'
      '<th>Worst split: max levels (8-bit units), % samples</th><th>ESTIMATE: keys with &gt; 1 picture</th></tr>')
for label, pp, pe, *_ in machines:
    if not (os.path.exists(pp) and os.path.getsize(pp)):
        continue
    p = load(pp)
    e = load(pe) if os.path.exists(pe) and os.path.getsize(pe) else None
    split = p['keys_with_more_than_one']
    most = max((len(p['counts'][k]) for k in split), default=1)
    diffs = [v for v in p['diff_top_two'].values() if v]
    worst = max(diffs, key=lambda v: (v['max_abs_8bit'], v['pct_differ']), default=None)
    wtxt = '%g, %.4f%%' % (worst['max_abs_8bit'], max(v['pct_differ'] for v in diffs)) if worst else '-'
    etxt = '-' if e is None else '%d of %d' % (len(e['keys_with_more_than_one']), len(e['distinct']))
    print('<tr><td>%s</td><td>%d</td><td class="%s">%d of %d</td><td>%d</td><td>%s</td><td class="%s">%s</td></tr>' % (
        label, p['processes'], 'bad' if split else 'ok', len(split), len(p['distinct']), most, wtxt,
        'ok' if e is not None and not e['keys_with_more_than_one'] else 'bad', etxt))
print('</table>')

print('<h3>Which keys split (PATIENT)</h3>\n<table><tr><th>Machine</th><th>Keys</th></tr>')
for label, pp, *_ in machines:
    if os.path.exists(pp) and os.path.getsize(pp):
        p = load(pp)
        names = sorted({k.split()[0] for k in p['keys_with_more_than_one']})
        print('<tr><td>%s</td><td>%s</td></tr>' % (label, ', '.join('<code>%s</code>' % n for n in names) or 'none'))
print('</table>')

print('<h3>Shared FFTW problems</h3>\n<table><tr><th>Machine</th><th>Build</th><th>DFTTest problems</th>'
      '<th>FFT3DFilter problems</th><th>Shared</th><th>FFT3DFilter changed after DFTTest</th></tr>')
for label, _, _, wp, we, *_ in machines:
    for b, w in (('PATIENT', wp), ('ESTIMATE', we)):
        if os.path.exists(w) and os.path.getsize(w):
            r = load(w)
            print('<tr><td>%s</td><td>%s</td><td>%d</td><td>%d</td><td class="%s">%d</td><td>%s</td></tr>' % (
                label, b, r['dfttest_problems'], r['fft3d_problems'],
                'ok' if not r['shared_problems'] else 'bad', len(r['shared_problems']),
                ', '.join(r['fft3d_mixed_differs_from_fresh']) or 'none'))
print('</table>')

print('<h3>ESTIMATE against PATIENT</h3>\n<table><tr><th>Machine</th><th>Keys that move</th>'
      '<th>Largest move (8-bit units)</th><th>Largest share of samples</th>'
      '<th>Keys identical to a PATIENT picture</th></tr>')
for label, *_, mv, _ in machines:
    if os.path.exists(mv) and os.path.getsize(mv):
        r = load(mv)
        moved = {k: v for k, v in r.items() if all(x['max_abs'] for x in v['vs_patient'])}
        same = [k for k, v in r.items() if any(not x['max_abs'] for x in v['vs_patient'])]
        allv = [x for v in moved.values() for x in v['vs_patient']]
        print('<tr><td>%s</td><td>%d of %d</td><td>%s</td><td>%s</td><td>%d</td></tr>' % (
            label, len(moved), len(r),
            '%g' % max((x['max_abs_8bit'] for x in allv), default=0),
            '%.4f%%' % max((x['pct_differ'] for x in allv), default=0), len(same)))
print('</table>')

print('<h3>Speed (median of runs)</h3>\n<table><tr><th>Machine</th><th>Call</th>'
      '<th>Create PATIENT / ESTIMATE (s)</th><th>fps PATIENT / ESTIMATE</th></tr>')
for label, *_, sp in machines:
    if os.path.exists(sp) and os.path.getsize(sp):
        runs = speed(sp)
        for k in sorted(runs['patient'][0]):
            m = {b: (statistics.median(r[k]['create_s'] for r in rs), statistics.median(r[k]['fps'] for r in rs))
                 for b, rs in runs.items()}
            print('<tr><td>%s</td><td><code>%s</code></td><td>%.3f / %.3f</td><td>%.1f / %.1f</td></tr>' % (
                label, k, m['patient'][0], m['estimate'][0], m['patient'][1], m['estimate'][1]))
print('</table>')
