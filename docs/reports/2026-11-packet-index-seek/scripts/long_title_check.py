"""B on the 2 h title: frames at 10/50/95 % through today's arguments and
the byte start (M2), against a reference that uses neither: a decode from a
key packet three GOPs earlier with -copyts, every picture named by its own
PTS (`-f framemd5` of the luma). On a constant-rate PAL title with no reset,
frame N is the picture whose PTS is the first picture's + N frames.

  long_title_check.py <title.mpg>     appends to data/long_title.json
"""
import json
import os
import subprocess
import sys
from fractions import Fraction

import pktlib as L
import today_args as today

SHOW = 5


def framemd5(inp, args, count):
    r = subprocess.run([L.FF, '-v', 'error', *args, '-i', inp, '-map', '0:v:0', '-frames:v', str(count),
                        '-fps_mode', 'passthrough', '-enc_time_base:v', '1/90000', '-pix_fmt', 'gray',
                        '-f', 'framemd5', '-'],
                       capture_output=True, text=True)
    tb, rows = None, []
    for line in r.stdout.splitlines():
        if line.startswith('#tb 0:'):
            tb = Fraction(line.split(':')[1].strip().replace(' ', ''))
        elif line and not line.startswith('#'):
            f = [x.strip() for x in line.split(',')]
            rows.append((int(f[2]) * tb, f[5]))
    return rows


def main():
    inp = sys.argv[1]
    info = L.source_info(inp)
    idx, tb = L.packet_index(inp)
    keys = [i for i, p in enumerate(idx) if p['key']]
    first_pts = min(p['pts'] for p in idx[:64] if p['pts'] is not None) * tb
    step = Fraction(1, 1) / Fraction(info['fps']).limit_denominator(1001)
    total = len(idx)
    out = []
    for frac in (0.10, 0.50, 0.95):
        n = int(total * frac)
        target = first_pts + n * step
        k = max(i for i in keys if idx[i]['pts'] is not None and idx[i]['pts'] * tb <= target)
        k_ref = keys[max(0, keys.index(k) - 3)]
        ref = framemd5(inp, ['-copyts', '-skip_initial_bytes', str(idx[k_ref]['pos'])], 200)
        by_pts = {pts: h for pts, h in ref}
        want = [by_pts.get(target + i * step) for i in range(SHOW)]
        a, f = L.today_args(info, n)
        got_today, _ = L.decode(info, a, f, SHOW)
        mk = [i for i in keys if idx[i]['pts'] is not None and idx[i]['pts'] * tb <= target - step / 2][-1]
        got_m2, _ = L.decode(info, ['-copyts', '-skip_initial_bytes', str(idx[mk]['pos'])], f, SHOW)
        # framemd5 hashes the same gray plane bytes L.decode hashes.
        row = dict(frac=frac, frame=n, reference_found=all(want),
                   today_exact=got_today == want, m2_exact=got_m2 == want,
                   today_args=a, m2_key_packet=mk)
        print(json.dumps(row), flush=True)
        out.append(row)
    path = os.path.join(L.DATA, 'long_title.json')
    json.dump(dict(input=os.path.basename(inp), packets=total, rows=out), open(path, 'w'), indent=1)


if __name__ == '__main__':
    main()
