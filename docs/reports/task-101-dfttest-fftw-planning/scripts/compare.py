"""How far the ESTIMATE build's pictures are from the PATIENT build's: for
every key, the ESTIMATE picture against each distinct PATIENT picture seen.
Fill each dump directory first with `xproc.py <dir> all`, run in fresh
processes with each bundle (several for PATIENT, so its plans vary).
Plain Python, no bundle needed. One JSON document.
argv: patient_dump_dir estimate_dump_dir"""
import array
import glob
import json
import os
import sys


def index(d):
    out = {}
    for p in glob.glob(os.path.join(d, 'index-*.json')):
        with open(p) as fh:
            for k, h in json.load(fh).items():
                out.setdefault(k, set()).add(h)
    return out


def diff(d1, h1, d2, h2, depth):
    t = 'B' if depth == 8 else 'H'
    a, b = array.array(t), array.array(t)
    with open(os.path.join(d1, h1 + '.raw'), 'rb') as f:
        a.frombytes(f.read())
    with open(os.path.join(d2, h2 + '.raw'), 'rb') as f:
        b.frombytes(f.read())
    n = differ = mx = 0
    for x, y in zip(a, b):
        n += 1
        d = abs(x - y)
        if d:
            differ += 1
            mx = max(mx, d)
    return {'max_abs': mx, 'max_abs_8bit': mx / (1 << (depth - 8)),
            'pct_differ': round(100.0 * differ / n, 4)}


pd, ed = sys.argv[1], sys.argv[2]
pi, ei = index(pd), index(ed)
out = {}
for k in sorted(ei):
    depth = int(k.split()[-1])
    out[k] = {'estimate_pictures': len(ei[k]), 'patient_pictures': len(pi.get(k, ())),
              'vs_patient': [diff(ed, eh, pd, ph, depth)
                             for eh in sorted(ei[k]) for ph in sorted(pi.get(k, ()))]}
print(json.dumps(out, indent=1, sort_keys=True))
