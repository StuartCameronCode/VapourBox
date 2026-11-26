"""Runs xproc.py in `processes` fresh processes (with the interpreter this is
run by; run.sh / run.ps1 set up the bundle's environment), counts the
distinct pictures per key and, for each key with more than one, measures the
two most common pictures against each other: the largest difference (in the
picture's own levels and in 8-bit units) and the share of samples that
differ. Prints one JSON document; progress on stderr.
argv: processes [dump_dir]"""
import array
import json
import os
import platform
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
procs = int(sys.argv[1]) if len(sys.argv) > 1 else 20
dump = sys.argv[2] if len(sys.argv) > 2 else tempfile.mkdtemp()
os.makedirs(dump, exist_ok=True)


def run(*args):
    r = subprocess.run([sys.executable, os.path.join(HERE, 'xproc.py'), *args],
                       capture_output=True, text=True, cwd=HERE)
    if r.returncode != 0:
        raise SystemExit('xproc.py %s failed (%d):\n%s' % (args, r.returncode, r.stderr[-3000:]))
    return json.loads(r.stdout.strip().splitlines()[-1])


seen, plugin = {}, None
for i in range(procs):
    print('xproc %d/%d' % (i + 1, procs), file=sys.stderr, flush=True)
    res = run()
    plugin = res['plugin']
    for k, h in res['hashes'].items():
        seen.setdefault(k, {}).setdefault(h, 0)
        seen[k][h] += 1

split = {k: v for k, v in seen.items() if len(v) > 1}
top = {k: sorted(v, key=v.get, reverse=True)[:2] for k, v in split.items()}


def missing():
    return sorted(k for k, hs in top.items()
                  if not all(os.path.exists(os.path.join(dump, h + '.raw')) for h in hs))


# Fresh processes until both pictures of every split key have been written
# out (each process may plan either way; give up after as many tries as the
# probe ran).
for i in range(procs):
    keys = missing()
    if not keys:
        break
    print('dump %d keys, try %d' % (len(keys), i + 1), file=sys.stderr, flush=True)
    run(dump, *keys)
diffs = {}
for k, hs in sorted(top.items()):
    paths = [os.path.join(dump, h + '.raw') for h in hs]
    if not all(os.path.exists(p) for p in paths):
        diffs[k] = None
        continue
    depth = int(k.split()[-1])
    a, b = array.array('B' if depth == 8 else 'H'), array.array('B' if depth == 8 else 'H')
    with open(paths[0], 'rb') as fa, open(paths[1], 'rb') as fb:
        a.frombytes(fa.read())
        b.frombytes(fb.read())
    n = differ = mx = 0
    for x, y in zip(a, b):
        n += 1
        d = abs(x - y)
        if d:
            differ += 1
            if d > mx:
                mx = d
    diffs[k] = {'max_abs': mx, 'max_abs_8bit': mx / (1 << (depth - 8)),
                'pct_differ': round(100.0 * differ / n, 4)}

print(json.dumps({
    'machine': platform.platform(), 'processor': platform.processor(),
    'cpu_count': os.cpu_count(), 'processes': procs, 'plugin': plugin,
    'distinct': {k: len(v) for k, v in sorted(seen.items())},
    'counts': {k: sorted(v.values(), reverse=True) for k, v in sorted(seen.items())},
    'keys_with_more_than_one': sorted(split),
    'diff_top_two': diffs,
}, indent=1, sort_keys=True))
