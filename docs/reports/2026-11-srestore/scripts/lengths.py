"""Output length and which rate pairs Unblend accepts.

For every source rate x target the app can send: srestore's own
(frfac, numr, denm), whether that ratio is the exact target/source ratio,
and, where it is, the port's output length against floor(n * num / den),
counted by rendering every frame of a blank clip of that length.
Writes ../data/ratio_table.json, which worker/src/models/unblend_parameters.rs's
tests embed: the Rust port of srestore.ratio must agree row for row.
"""
import json
import os
from fractions import Fraction

import probelib as P
from probelib import core, vs

SOURCES = [(50, 1), (60000, 1001), (60, 1), (25, 1), (30000, 1001), (48, 1), (24000, 1001), (24, 1),
           (120000, 1001), (100, 1)]
# Named targets, then custom rates as FrameRateParameters::custom_fps_fraction
# turns them into fractions.
TARGETS = [(25, 1), (30000, 1001), (24000, 1001), (24, 1), (50, 1), (60000, 1001),
           (48, 1), (20, 1), (12, 1), (15, 1), (18, 1), (16, 1), (10, 1), (30, 1), (24000, 1001 * 2)]
LENGTHS = [1, 2, 7, 97, 300, 1001, 2401]

rows = []
bad_len = []
for s in SOURCES:
    for t in TARGETS:
        frfac, numr, denm = P.srestore.ratio(s[0], s[1], t[0], t[1])
        exact = Fraction(t[0], t[1]) / Fraction(s[0], s[1])
        accepted = frfac != 1 and Fraction(numr, denm) == exact
        row = {'source': list(s), 'target': list(t), 'frfac': frfac, 'numr': numr, 'denm': denm,
               'accepted': accepted}
        if accepted:
            counts = []
            for n in LENGTHS:
                want = n * exact.numerator // exact.denominator
                if want == 0:
                    counts.append(0)  # refused by the script and the worker alike
                    continue
                clip = core.std.BlankClip(format=vs.YUV420P8, width=64, height=48, length=n,
                                          fpsnum=s[0], fpsden=s[1])
                out = P.srestore.unblend(clip, t[0], t[1], window=8)
                rendered = sum(1 for _ in out.frames()) if n <= 300 else len(out)
                counts.append(rendered)
                if rendered != want or (out.fps_num, out.fps_den) != (Fraction(*t).numerator, Fraction(*t).denominator):
                    bad_len.append((s, t, n, rendered, want))
            row['counts'] = dict(zip(map(str, LENGTHS), counts))
        rows.append(row)

acc = [r for r in rows if r['accepted']]
print('pairs', len(rows), 'accepted', len(acc), 'length mismatches', bad_len)
for r in rows:
    if not r['accepted'] and r['frfac'] != 1:
        print('refused (ratio differs):', r['source'], r['target'], r['numr'], r['denm'])
json.dump({'lengths': LENGTHS, 'rows': rows}, open(os.path.join(P.HERE, '..', 'data', 'ratio_table.json'), 'w'), indent=0)
