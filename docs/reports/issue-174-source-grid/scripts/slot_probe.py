"""§2: untrimmed decodes. For each fixture: stored frames, the slots the old
constant-rate decode produced and the grid decode produces, the independent
timestamp timeline, and whether each matches it.

  python3 slot_probe.py [--json out.json]
"""
import json
import os
import sys
from gridlib import FIXTURES, resource, probe, stored, cfr_decode, grid_decode, timeline, name


def main():
    rows = []
    for f in FIXTURES:
        path = resource(f)
        p = probe(path)
        st = stored(path, p)
        old_h = cfr_decode(path, p)
        new_h = grid_decode(path, p) if p['has_pts'] else None
        tl = timeline(path, p)
        tl_h = [st[k] for k in tl] if tl else None
        old = name(old_h, st)
        new = name(new_h, st) if new_h else None
        row = dict(file=f, rate=str(p['rate']), stored=len(st), old_slots=len(old),
                   grid_slots=len(new) if new else None, timeline=len(tl) if tl else None,
                   old_head=old[:10], grid_head=new[:10] if new else None,
                   old_eq_timeline=(old_h == tl_h) if tl else None,
                   grid_eq_timeline=(new_h == tl_h) if (tl and new_h) else None,
                   grid_eq_old=(new_h == old_h) if new_h else None,
                   has_pts=p['has_pts'])
        rows.append(row)
        print(f"{f:30s} {row['rate']:>10s} stored {len(st):4d}  old {len(old):4d} "
              f"grid {row['grid_slots'] if new else '(no grid)':>4}  timeline {row['timeline']}  "
              f"old=tl {row['old_eq_timeline']}  grid=tl {row['grid_eq_timeline']}  grid=old {row['grid_eq_old']}")
        if new_h and new_h != old_h:
            d = [(i, old[i], new[i]) for i, (a, b) in enumerate(zip(old_h, new_h)) if a != b]
            print(f"   old {old[:8]}  grid {new[:8]}  first differences {d[:4]}")
    if '--json' in sys.argv:
        json.dump(rows, open(sys.argv[sys.argv.index('--json') + 1], 'w'), indent=1)


if __name__ == '__main__':
    main()
