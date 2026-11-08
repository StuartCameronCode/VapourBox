"""Rebuilds nr_results.json from nr_compare.py's printed log.

The 2026-11-08 run crashed in its final parity step (a round-trip assertion
that compared a float mean with == 0) after the two-hour sweep, before the
script wrote its JSON; the sweep's per-strength rows existed only in memory.
The log (results/nr_compare.txt) has every best-strength row, which is what
the report's tables use; the parity step was re-run on its own
(PARITY_ONLY=1, results/nr_parity.txt). nr_compare.py now writes its JSON
after every fixture.

  python3 parse_nr_log.py results/nr_compare.txt > $SCRATCH/nr_results.json
"""
import json
import re
import sys

out = {'nfr': 10, 'fixtures': {}, 'source': 'parsed from nr_compare.txt'}
head = re.compile(r'== (\S+) sigma ([\d.]+) \(measured ([\d.]+)\); noisy Y ([\d.]+) dB')
row = re.compile(r'  (.+?)\s+best\s+([\d.]+)(?: \(edge of sweep\))?\s+Y ([\d.]+)\s+U ([\d.]+)\s+([\d.]+) fps')
cur = None
for line in open(sys.argv[1]):
    m = head.search(line)
    if m:
        fx, sigma = m.group(1), m.group(2)
        cur = {'measured_sigma': float(m.group(3)), 'noisy_psnr_y': float(m.group(4)), 'methods': {}}
        out['fixtures'].setdefault(fx, {})[sigma] = cur
        continue
    m = row.match(line)
    if m and cur is not None:
        cur['methods'][m.group(1).strip()] = {
            'best_strength': float(m.group(2)), 'psnr_y': float(m.group(3)), 'psnr_u': float(m.group(4)),
            'edge_of_sweep': '(edge of sweep)' in line}
json.dump(out, sys.stdout, indent=1)
