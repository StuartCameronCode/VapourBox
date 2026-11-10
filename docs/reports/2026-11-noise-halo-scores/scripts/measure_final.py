"""The chosen noise and halo scores on every fixture: $SCRATCH/fx/final.json.

Same algorithm and thresholds as worker/src/noise_halo.rs (probelib.final_*):
each fixture's 8 frames are measured as 4 pairs of consecutive frames.
Prints each fixture with its ground-truth class and what the score says, then
the separation: the highest score among "clean" fixtures against the lowest
among "high" ones, per family.
"""
import json
import os

import numpy as np

import probelib as L

FX = L.scratch('fx')


def main():
    manifest = json.load(open(os.path.join(FX, 'manifest.json')))
    out = {}
    for e in manifest:
        frames = L.luma(e['path'], 0, 8)
        pairs = [(frames[i], frames[i + 1]) for i in range(0, len(frames) - 1, 2)]
        r = L.final_source(pairs, e['interlaced'])
        out[e['name']] = {**e, **r}
        n = '  -  ' if r['noise'] is None else f"{r['noise']:5.2f}"
        h = '  -   ' if r['halo'] is None else f"{r['halo']:6.2f}"
        print(f"{e['name']:28s} noise {n} ({e['noise_class']:5s}) {'HIGH' if r['noise_high'] else '    '}  "
              f"halo {h} ({e['halo_class']:5s}, {r['halo_edges']:6d} edges) {'HIGH' if r['halo_high'] else ''}",
              flush=True)
    json.dump(out, open(os.path.join(FX, 'final.json'), 'w'), indent=1)

    for key, cls_key, thr in [('noise', 'noise_class', L.NOISE_HIGH), ('halo', 'halo_class', L.HALO_HIGH)]:
        clean = [(v[key], n) for n, v in out.items() if v[cls_key] == 'clean' and v[key] is not None]
        high = [(v[key], n) for n, v in out.items() if v[cls_key] == 'high' and v[key] is not None]
        wrong_pos = [n for s, n in clean if s >= thr]
        missed = [n for s, n in high if s < thr]
        print(f"\n{key}: threshold {thr}; clean max {max(clean)}; high min {min(high)}")
        print(f"  false positives (clean at/above threshold): {wrong_pos}")
        print(f"  missed (high below threshold): {len(missed)} of {len(high)}: {missed}")


if __name__ == '__main__':
    main()
