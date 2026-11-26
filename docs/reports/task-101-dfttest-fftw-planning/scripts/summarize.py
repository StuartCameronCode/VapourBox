"""Prints one probe directory's findings (the CI workflow's out/, or a local
data/ set): per bundle, the keys with more than one picture and how far
apart; shared FFTW problems; median speed.
argv: dir"""
import glob
import json
import os
import statistics
import sys

d = sys.argv[1]


def load(p):
    with open(p, encoding='utf-8-sig') as fh:
        return json.load(fh)


for p in sorted(glob.glob(os.path.join(d, 'probe-*.json'))):
    if not os.path.getsize(p):
        continue  # still being written
    r = load(p)
    split = r['keys_with_more_than_one']
    print('%s: %s, %d processes, %d keys, %d with more than one picture' % (
        os.path.basename(p), r['plugin'], r['processes'], len(r['distinct']), len(split)))
    for k in split:
        print('   %-28s %-12s %s' % (k, r['counts'][k], r['diff_top_two'].get(k)))
for p in sorted(glob.glob(os.path.join(d, 'wisdom-*.json'))):
    r = load(p)
    print('%s: shared problems %d, FFT3DFilter differs after DFTTest: %s' % (
        os.path.basename(p), len(r['shared_problems']), r['fft3d_mixed_differs_from_fresh']))
mp = os.path.join(d, 'move.json')
if os.path.exists(mp):
    for k, v in load(mp).items():
        worst = max(v['vs_patient'], key=lambda x: x['max_abs'], default=None)
        print('move %-28s estimate %d vs patient %d pictures, worst %s' % (
            k, v['estimate_pictures'], v['patient_pictures'], worst))
sp = os.path.join(d, 'speed.jsonl')
if os.path.exists(sp):
    runs = {}
    with open(sp, encoding='utf-8-sig') as fh:
        for line in fh:
            if line.strip():
                j = json.loads(line)
                runs.setdefault(j['build'], []).append(j['result']['speed'])
    for b, rs in runs.items():
        for k in sorted(rs[0]):
            print('speed %-9s %-26s create %.3f s  first %.3f s  %.1f fps' % (
                b, k, statistics.median(r[k]['create_s'] for r in rs),
                statistics.median(r[k]['first_frame_s'] for r in rs),
                statistics.median(r[k]['fps'] for r in rs)))
