"""Order, threads and preview windows: is the port a pure function?

(a) The encode through vspipe at one request at a time vs the default
    request count: the Y4M outputs must be byte-identical.
(b) A preview-style window (decode from n - radius, padded to the encode's
    phase) must give the encode's frame, at several targets.
(c) The temporal reach: which input frames one output frame reads.
Also runs (a) on havsfunc as shipped, for the record.
"""
import hashlib
import json
import os
import subprocess
import sys

import probelib as P
from probelib import core, vs

WINDOW = int(os.environ.get('UNBLEND_WINDOW', '48'))
VPY = r'''
import os, sys
sys.path.insert(0, {here!r})
import probelib as P
clip = P.bobbed({fx!r})
num, den = P.TARGETS[{fx!r}]
if {variant!r} == 'port':
    out = P.srestore.unblend(clip, num, den, window={window})
else:
    out = P.haf.srestore(clip, frate=num / den)
out.set_output()
'''


def vspipe_md5(fx, variant, requests):
    path = os.path.join(P.SCRATCH, f'order_{fx}_{variant}.vpy')
    open(path, 'w').write(VPY.format(here=P.HERE, fx=fx, variant=variant, window=WINDOW))
    cmd = [os.path.join(P.DEPS, 'vapoursynth', 'vspipe'), '-c', 'y4m']
    if requests:
        cmd += ['-r', str(requests)]
    cmd += [path, '-']
    # The vspipe wrapper finds its own Python config under the bundle.
    env = {k: v for k, v in os.environ.items() if k not in ('XDG_CONFIG_HOME', 'PYTHONHOME')}
    proc = subprocess.run(cmd, capture_output=True, env=env)
    if proc.returncode:
        sys.exit(proc.stderr.decode(errors='replace')[-2000:])
    data = proc.stdout
    return hashlib.md5(data).hexdigest(), len(data)


def frame_bytes(f):
    out = []
    for p in range(f.format.num_planes):
        arr = f[p]
        out.append(bytes(memoryview(arr).cast('B')) if memoryview(arr).contiguous else bytes(arr))
    return b''.join(out)


def preview_frame(clip, num, den, m, radius):
    """What a preview of output frame m computes: the input window
    [n - radius, n + radius], with copies of its first frame in front so its
    phase (index mod denm) is the encode's, and the detector told where the
    real frames begin."""
    from fractions import Fraction
    frfac, numr, denm = P.srestore.ratio(clip.fps_num, clip.fps_den, num, den)
    r = Fraction(num, den) / Fraction(clip.fps_num, clip.fps_den)
    n = m * r.denominator // r.numerator
    first = max(0, n - radius)
    last = min(len(clip), n + radius + 1)
    pad = first % denm
    win = clip[first:last]
    if pad:
        win = win[0] * pad + win
    out = P.srestore.unblend(win, num, den, origin=pad, window=WINDOW)
    local = m - (first - pad) * r.numerator // r.denominator
    return out.get_frame(local)


result = {'window': WINDOW}
for fx in ('film', 'pal'):
    clip = P.bobbed(fx)
    num, den = P.TARGETS[fx]
    row = {}
    for variant in ('port', 'havsfunc'):
        a = vspipe_md5(fx, variant, 1)
        b = vspipe_md5(fx, variant, None)
        row[f'{variant}_r1_equals_default'] = a == b
    enc = P.srestore.unblend(clip, num, den, window=WINDOW)
    # (c) reach: record which input frames each output frame requests.
    seen = []

    def spy(n, f):
        seen.append(n)
        return f

    spied = core.std.ModifyFrame(clip, clip, spy)
    probe_out = P.srestore.unblend(spied, num, den, window=WINDOW)
    reach_back, reach_ahead = 0, 0
    from fractions import Fraction
    r = Fraction(num, den) / Fraction(clip.fps_num, clip.fps_den)
    core.num_threads = 1
    for m in range(40, len(probe_out) - 10, 7):
        seen.clear()
        # A fresh node each time, so nothing is served from the cache.
        probe_out = P.srestore.unblend(core.std.ModifyFrame(clip, clip, spy), num, den, window=WINDOW)
        probe_out.get_frame(m)
        n = m * r.denominator // r.numerator
        reach_back = max(reach_back, n - min(seen))
        reach_ahead = max(reach_ahead, max(seen) - n)
    core.num_threads = 0 or os.cpu_count()
    row['reach_back'] = reach_back
    row['reach_ahead'] = reach_ahead
    # The replay starts at n - WINDOW: that frame must be in the window even
    # though the oldest pixels its measurements read are two frames later.
    # (A first run with radius = reach_back, 46, mismatched at 6 of 22
    # targets on the film fixture for exactly this reason.)
    radius = max(WINDOW, reach_back) + max(reach_ahead, 4)
    row['preview_radius_used'] = radius
    mismatch = []
    targets = sorted(set([0, 1, 5, WINDOW // 3, len(enc) // 2, len(enc) - 2, len(enc) - 1]
                         + list(range(10, len(enc), 9))))
    for m in targets:
        a = frame_bytes(enc.get_frame(m))
        b = frame_bytes(preview_frame(clip, num, den, m, radius))
        if a != b:
            mismatch.append(m)
    row['preview_targets'] = len(targets)
    row['preview_mismatches'] = mismatch
    result[fx] = row
    print(fx, row, flush=True)
json.dump(result, open(os.path.join(P.SCRATCH, 'order.json'), 'w'), indent=1)
