"""Per case: how many previews showed what the encode shows for their source
frame (measure.verdict), and how far off in film frames the rest were.

  python3 summary.py before.json after.json
"""
import json
import sys
from collections import Counter

from measure import CASES, verdict


def load(path):
    return {c['case']: c for c in json.load(open(path))}


before, after = load(sys.argv[1]), load(sys.argv[2])
print(f'{"case":14s} {"before":>9s} {"after":>9s}  film off before -> after')
for name in CASES:
    cells, offs = [], []
    for d in (before, after):
        c = d[name]
        rows = c['rows']
        cells.append(f'{sum(verdict(r, c["encode_film"]) for r in rows)}/{len(rows)}')
        offs.append(dict(sorted(Counter(r['film_off'] for r in rows if 'film_off' in r).items())))
    print(f'{name:14s} {cells[0]:>9s} {cells[1]:>9s}  {offs[0]} -> {offs[1]}')
