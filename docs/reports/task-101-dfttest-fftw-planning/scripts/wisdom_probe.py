"""Runs wisdom.py's three modes in fresh processes and compares: the
problems DFTTest planned against FFT3DFilter's (shared = same md5), and
FFT3DFilter's pictures after DFTTest planned in the same process against
fresh ones (`runs` mixed processes, `runs` fresh). One JSON document.
argv: [runs]"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
runs = int(sys.argv[1]) if len(sys.argv) > 1 else 5


def run(mode):
    r = subprocess.run([sys.executable, os.path.join(HERE, 'wisdom.py'), mode],
                       capture_output=True, text=True, cwd=HERE)
    if r.returncode != 0:
        raise SystemExit('wisdom.py %s failed (%d):\n%s' % (mode, r.returncode, r.stderr[-3000:]))
    return json.loads(r.stdout.strip().splitlines()[-1])


d, f = run('dfttest'), run('fft3d')
shared = sorted(set(d['problems']) & set(f['problems']))
fresh, mixed = {}, {}
for i in range(runs):
    print('wisdom %d/%d' % (i + 1, runs), file=sys.stderr, flush=True)
    for k, h in run('fft3d')['hashes'].items():
        fresh.setdefault(k, set()).add(h)
    for k, h in run('mixed')['hashes'].items():
        mixed.setdefault(k, set()).add(h)
print(json.dumps({
    'dfttest_problems': len(d['problems']), 'dfttest_entries': d['entries'],
    'fft3d_problems': len(f['problems']), 'fft3d_entries': f['entries'],
    'shared_problems': shared,
    'fft3d_pictures_fresh': {k: len(v) for k, v in sorted(fresh.items())},
    'fft3d_mixed_differs_from_fresh': sorted(k for k in mixed if mixed[k] - fresh.get(k, set())),
    'errors': sorted(k for k, v in {**d['hashes'], **f['hashes']}.items() if v.startswith('error')),
}, indent=1, sort_keys=True))
