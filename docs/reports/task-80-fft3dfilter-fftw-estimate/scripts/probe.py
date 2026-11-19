"""Everything this report measures on one machine, with the interpreter it
is run by (run.sh / run.ps1 set up the bundle's environment):
  xproc   `processes` fresh processes per measure value (0, 1, default),
          counting distinct hashes per key;
  wisdom  one process that plans at 1 then 0, against the fresh 0 hashes;
  speed   speed.py per measure value, `speed_runs` processes each (median);
  move    move.py once.
argv: [processes] [speed_runs] [parts]. Prints one JSON document; progress on
stderr. parts is a comma list of xproc,wisdom,speed,move (default all)."""
import json
import os
import platform
import statistics
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
procs = int(sys.argv[1]) if len(sys.argv) > 1 else 20
speed_runs = int(sys.argv[2]) if len(sys.argv) > 2 else 3
parts = (sys.argv[3] if len(sys.argv) > 3 else 'xproc,wisdom,speed,move').split(',')


def run(script, *args):
    r = subprocess.run([sys.executable, os.path.join(HERE, script), *args],
                       capture_output=True, text=True, cwd=HERE)
    if r.returncode != 0:
        raise SystemExit('%s %s failed (%d):\n%s' % (script, args, r.returncode, r.stderr[-3000:]))
    return json.loads(r.stdout.strip().splitlines()[-1])


out = {'machine': platform.platform(), 'processor': platform.processor(),
       'cpu_count': os.cpu_count(), 'processes': procs}
fresh0 = None
if 'xproc' in parts:
    out['xproc'] = {}
    for m in ('0', '1', 'default'):
        seen = {}
        for i in range(procs):
            print('xproc measure=%s %d/%d' % (m, i + 1, procs), file=sys.stderr, flush=True)
            for k, h in run('xproc.py', m)['hashes'].items():
                seen.setdefault(k, {}).setdefault(h, 0)
                seen[k][h] += 1
        if m == '0':
            fresh0 = {k: max(v, key=v.get) for k, v in seen.items()}
        out['xproc'][m] = {'distinct': {k: len(v) for k, v in sorted(seen.items())},
                           'keys_with_more_than_one': sorted(k for k, v in seen.items() if len(v) > 1),
                           'hashes': {k: v for k, v in sorted(seen.items())}}
if 'wisdom' in parts:
    print('wisdom', file=sys.stderr, flush=True)
    w = run('wisdom.py')['hashes']
    if fresh0 is None:
        fresh0 = run('xproc.py', '0')['hashes']
    out['wisdom'] = {'differs_from_fresh_0': sorted(k for k in w if w[k] != fresh0.get(k)),
                     'keys': len(w)}
if 'speed' in parts:
    out['speed'] = {}
    runs = {'0': [], '1': []}
    for i in range(speed_runs):
        for m in ('0', '1'):  # interleaved, so drift (thermal, neighbours) hits both
            print('speed measure=%s %d/%d' % (m, i + 1, speed_runs), file=sys.stderr, flush=True)
            runs[m].append(run('speed.py', m)['speed'])
    for m, rs in runs.items():
        out['speed'][m] = {k: {f: statistics.median(r[k][f] for r in rs) for f in rs[0][k]}
                           for k in rs[0]}
if 'move' in parts:
    print('move', file=sys.stderr, flush=True)
    out['move'] = {**run('move.py', '8'), **run('move.py', '16')}
print(json.dumps(out, indent=1, sort_keys=True))
