"""The exploration behind the chosen measures, one table per mode. Prints the
tables the report quotes in "Candidates"; filter fixtures by name fragments.

  python explore.py noise-spatial [names...]  Immerkaer p10, plane-fit std,
                                              Immerkaer at coarser scales
  python explore.py noise-mc [names...]       spatial p25 against the
                                              motion-compensated estimate
                                              (R=radius, default 6; 10 chosen)
  python explore.py halo-zone [names...]      mean-zone halo (rejected)
  python explore.py halo-reach [names...]     max-based halo, 1 vs 3 lines
                                              each way (REACH=1,3)
  python explore.py halo-flat [names...]      relative plateau tolerance
                                              0 / 0.03 / 0.05 (needs final.json)
"""
import json
import os
import sys

import numpy as np

import probelib as L

FX = L.scratch('fx')


def fixtures(pats, skip_sharpened=False):
    for e in json.load(open(os.path.join(FX, 'manifest.json'))):
        if pats and not any(p in e['name'] for p in pats):
            continue
        if skip_sharpened and not pats and ('usm' in e['name'] or 'peak' in e['name']):
            continue
        yield e, L.luma(e['path'], 0, 8)


def sig_label(e):
    return '' if e['sigma'] is None else f"{e['sigma']:g}"


def noise_spatial(pats):
    for e, fr in fixtures(pats, True):
        il = e['interlaced']
        imm = np.nanmedian([L.noise_blocks(f, il) for f in fr])
        pl = {p: np.nanmedian([L.noise_plane(f, il, pct=p) for f in fr]) for p in (5, 10, 25)}
        cx = np.nanmedian([L.noise_blocks_coarse(f, il, fx=2, fy=1) for f in fr])
        c22 = np.nanmedian([L.noise_blocks_coarse(f, il, fx=2, fy=2) for f in fr])
        print(f"{e['name']:28s} {e['noise_class']:5s} {sig_label(e):>3s} imm10 {imm:5.2f} "
              f"plane5 {pl[5]:5.2f} plane10 {pl[10]:5.2f} plane25 {pl[25]:5.2f} x2 {cx:5.2f} 2x2 {c22:5.2f}",
              flush=True)


def noise_mc(pats):
    radius = int(os.environ.get('R', 6))
    for e, fr in fixtures(pats, True):
        il = e['interlaced']
        sp = np.percentile([L.noise_blocks(f, il) for f in fr], 25)
        mc = [L.noise_mc(fr[i], fr[i + 1], il, radius=radius) for i in range(0, 8, 2)]
        print(f"{e['name']:28s} {e['noise_class']:5s} {sig_label(e):>3s} spatial {sp:5.2f} "
              f"mc {np.median(mc):5.2f} (min {min(mc):5.2f} max {max(mc):5.2f})", flush=True)


def halo_zone(pats):
    for e, fr in fixtures(pats):
        il = e['interlaced']
        sig = float(np.nanmedian([L.noise_blocks(f, il) for f in fr]))
        p = np.concatenate([L.coherent_edges(f, sig, il, profiles=True) for f in fr])
        s = []
        for near in [(1, 3), (2, 4), (1, 5)]:
            r = L.halo_mean_zone(p, near)
            s.append(f"{near}: {r['score']:6.2f} ({r['over']:6.1f}/{r['under']:6.1f})")
        print(f"{e['name']:28s} {e['halo_class']:5s} n {p.shape[0]:6d} " + '  '.join(s), flush=True)


def halo_reach(pats):
    reaches = [int(r) for r in os.environ.get('REACH', '1,3').split(',')]
    for e, fr in fixtures(pats):
        il = e['interlaced']
        sig = float(np.nanmedian([L.noise_blocks(f, il) for f in fr]))
        s = []
        for reach in reaches:
            r = L.halo_score(np.concatenate([L.coherent_edges(f, sig, il, reach=reach) for f in fr]))
            s.append(f"r{reach}: n {r['edges']:5d} mean {r['score']:6.2f} med {r['median']:6.2f}")
        print(f"{e['name']:28s} {e['halo_class']:5s} sig {sig:5.2f} " + ' | '.join(s), flush=True)


def halo_flat(pats):
    fin = json.load(open(os.path.join(FX, 'final.json')))
    for e, fr in fixtures(pats):
        il = e['interlaced']
        sig = fin[e['name']]['noise'] or 0.0
        s = []
        for rel in (0.0, 0.03, 0.05):
            ou = np.concatenate([L.coherent_edges(f, sig, il, reach=3, flat_rel=rel) for f in fr])
            two = np.minimum(ou[:, 0], ou[:, 1]) if len(ou) else np.zeros(0)
            s.append(f"rel {rel}: n {len(two):5d} {two.mean() * 100 if len(two) else float('nan'):6.2f}")
        print(f"{e['name']:28s} {e['halo_class']:5s} sig {sig:4.2f} " + ' | '.join(s), flush=True)


if __name__ == '__main__':
    mode, pats = sys.argv[1], sys.argv[2:]
    {'noise-spatial': noise_spatial, 'noise-mc': noise_mc, 'halo-zone': halo_zone,
     'halo-reach': halo_reach, 'halo-flat': halo_flat}[mode](pats)
