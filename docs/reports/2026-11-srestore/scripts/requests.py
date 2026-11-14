"""Why havsfunc's srestore cannot be used on VapourSynth R78.

Copies the bundle's havsfunc.py into the scratch directory with one line added
after `jmp = lfr + 1 == n` that logs (n, jmp), then runs srestore on the
deinterlaced film fixture through vspipe at 1 and at 8 concurrent requests.
`jmp` is true only when the detector is called for the frame after the last
one it saw; that is the only time its history advances. Also records the
"Critical" message R78 prints for std.Cache(make_linear=True).
"""
import json
import os
import subprocess

import probelib as P

src = open(os.path.join(P.DEPS, 'python-packages', 'havsfunc.py')).read()
line = "        jmp = lfr + 1 == n\n"
assert src.count(line) == 1
src = src.replace(line, line + "        import sys as _s; print('EVAL', n, int(jmp), file=_s.stderr)\n")
mod = os.path.join(P.SCRATCH, 'havsfunc_requests.py')
open(mod, 'w').write(src)

vpy = os.path.join(P.SCRATCH, 'requests.vpy')
open(vpy, 'w').write(f'''
import sys
sys.path.insert(0, {P.SCRATCH!r})
sys.path.insert(0, {P.HERE!r})
import probelib as P
import havsfunc_requests as haf
clip = P.bobbed('film')
haf.srestore(clip, frate=24000 / 1001).set_output()
''')

res = {}
env = {k: v for k, v in os.environ.items() if k not in ('XDG_CONFIG_HOME', 'PYTHONHOME')}
for r in (1, 8):
    proc = subprocess.run([os.path.join(P.DEPS, 'vapoursynth', 'vspipe'), '-r', str(r), vpy, '.'],
                          capture_output=True, text=True, env=env)
    evals = [tuple(map(int, l.split()[1:])) for l in proc.stderr.splitlines() if l.startswith('EVAL')]
    res[f'requests_{r}'] = {
        'evaluations': len(evals),
        'jmp_true': sum(j for _, j in evals),
        'first_frames_evaluated': [n for n, _ in evals[:12]],
        'make_linear_warning': next((l for l in proc.stderr.splitlines() if 'make_linear' in l), None),
    }
    print(r, res[f'requests_{r}'])
json.dump(res, open(os.path.join(P.SCRATCH, 'requests.json'), 'w'), indent=1)
