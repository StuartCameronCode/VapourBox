"""Every way of seeking, on every source: 8 pictures from each start frame,
each named by its index in the sequential decode. '!' marks a wrong start.

  python3 seek_probe.py [--json out.json]

Modes (seeklib.decode): plain (the worker before #169), relative (seek early,
trim without -copyts), copyts (the fix) at several prerolls, and copyts at the
preroll the worker's seek plan computes for the file."""
import json
import os
import sys
from seeklib import RES, probe, seek_plan, sequential, decode, indices
import make_variants

COUNT = 8
PREROLLS = (0.5, 1.0, 2.0, 3.0)


def starts(n):
    return [1, 2, 10, 30, 40, 41, 47, 49, 77, n - COUNT - 1, n - COUNT]


def run(path):
    seq = sequential(path)
    plan = seek_plan(path)
    modes = [('plain', 0.0)] + [('relative', p) for p in PREROLLS] + \
            [('copyts', p) for p in PREROLLS]
    if plan:
        modes.append(('plan', plan['preroll']))
    rows = []
    for mode, pre in modes:
        cells = []
        for st in starts(len(seq)):
            got = decode(path, st, COUNT, 'copyts' if mode == 'plan' else mode, pre)
            idx = indices(got, seq)
            cells.append({'start': st, 'first': idx[0] if idx else None,
                          'ok': got == seq[st:st + COUNT]})
        rows.append({'mode': mode, 'preroll': round(pre, 3), 'cells': cells})
    return {'source': os.path.basename(path), 'frames': len(seq),
            'format': probe(path)['format_name'], 'plan': plan, 'rows': rows}


def main():
    out = sys.argv[2] if sys.argv[1:2] == ['--json'] else None
    v = make_variants.build()
    paths = [os.path.join(RES, f) for f in
             ('seek_dvd_pal.mpg', 'seek_gop_late_video.ts', 'pal-dvbt-fieldcoded-25i.ts',
              'late_video_gop.ts', 'late_video_intra.ts', 'late_video.mp4')] + \
            [v[k] for k in ('dvd_pal.mpg', 'ts_25_video_first.ts', 'mkv_25.mkv')]
    results = []
    for p in paths:
        r = run(p)
        results.append(r)
        plan = r['plan']
        print(f"== {r['source']} ({r['format']}, {r['frames']} pictures) plan: "
              + (f"preroll {plan['preroll']:.2f} s (GOP {plan['gop']:.2f} + reorder "
                 f"{plan['reorder']:.2f} + margin)" if plan else 'none'))
        for row in r['rows']:
            cells = '  '.join(f"{c['start']}->{c['first']}{'' if c['ok'] else '!'}"
                              for c in row['cells'])
            print(f"  {row['mode']:8s} {row['preroll']:5.2f}: {cells}")
    if out:
        with open(out, 'w') as f:
            json.dump(results, f, indent=1)


if __name__ == '__main__':
    main()
