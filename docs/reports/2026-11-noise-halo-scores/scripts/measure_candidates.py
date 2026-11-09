"""Measure every candidate metric on every fixture: $SCRATCH/fx/candidates.json.

Candidates (all on luma, 8-bit units, per field on an interlaced fixture):

noise
  whole     Immerkaer's estimator over the whole picture
  blk5/10/20/50  the p-th percentile of per-16x16-block Immerkaer estimates,
            blocks within 4 levels of black or white left out
  temporal  the 10th percentile of per-block std(frame difference)/sqrt(2)
  tout/ydif ffmpeg signalstats TOUT and YDIF averages (what VCG v1 uses)

halo
  esf       the mean normalised edge profile across isolated step edges:
            min(overshoot, undershoot) in % of the step; zones 6..10 px out
  esf_n/w   the same with plateaus 4..8 and 8..12 px out
  vcg       fraction of strong edges with a two-sided overshoot (the idea of
            VCG's analyze_halo_level)

Each per-frame value is aggregated as the median over the fixture's frames.
"""
import json
import os
import re
import subprocess
import sys

import numpy as np

import probelib as L

FX = L.scratch('fx')


def signalstats(path):
    r = subprocess.run([L.FFMPEG, '-v', 'error', '-i', path, '-vf',
                        'signalstats=stat=tout,metadata=mode=print:file=-', '-f', 'null', '-'],
                       capture_output=True, text=True)
    tout = [float(m) for m in re.findall(r'lavfi\.signalstats\.TOUT=([0-9.eE+-]+)', r.stdout)]
    ydif = [float(m) for m in re.findall(r'lavfi\.signalstats\.YDIF=([0-9.eE+-]+)', r.stdout)]
    # YDIF is 0 on the first frame (no previous one).
    return (float(np.mean(tout)) if tout else float('nan'),
            float(np.mean(ydif[1:])) if len(ydif) > 1 else float('nan'))


def measure(entry, vcg=True):
    frames = L.luma(entry['path'], 0, 8)
    il = entry['interlaced']
    out = {}
    per = {k: [] for k in ['whole', 'blk5', 'blk10', 'blk20', 'blk50']}
    for f in frames:
        per['whole'].append(L.noise_whole(f, il))
        for p in [5, 10, 20, 50]:
            per[f'blk{p}'].append(L.noise_blocks(f, il, pct=p))
    for k, v in per.items():
        out[k] = float(np.nanmedian(v))
    out['temporal'] = float(np.nanmedian([L.noise_temporal(frames[i], frames[i + 1], il)
                                          for i in range(0, len(frames) - 1, 2)]))
    sigma = out['blk10']
    profiles = {'esf': (6, 10), 'esf_n': (4, 8), 'esf_w': (8, 12)}
    for key, (d1, d2) in profiles.items():
        ps = [L.edge_profiles(f, noise=sigma, d1=d1, d2=d2) for f in frames]
        p = np.concatenate(ps)
        r = L.halo_from_profiles(p, d1, d2)
        out[key] = r['score']
        out[key + '_over'] = r['over']
        out[key + '_under'] = r['under']
        out[key + '_edges'] = r['edges']
        if key == 'esf':
            out['esf_profile'] = p.mean(axis=0).tolist() if p.shape[0] else []
            # Spread over frames: the same statistic per frame.
            out['esf_frames'] = [L.halo_from_profiles(q, d1, d2)['score'] for q in ps]
    if vcg:
        rs = [L.halo_vcg_like(f) for f in frames[::3]]
        edges = sum(r['edges'] for r in rs)
        out['vcg_edges'] = edges
        out['vcg'] = (sum(r['ratio'] * r['edges'] for r in rs if r['edges']) / edges) if edges else float('nan')
    out['tout'], out['ydif'] = signalstats(entry['path'])
    return out


def main():
    manifest = json.load(open(os.path.join(FX, 'manifest.json')))
    only = sys.argv[1:]
    path = os.path.join(FX, 'candidates.json')
    results = json.load(open(path)) if os.path.exists(path) else {}
    for e in manifest:
        if only and not any(o in e['name'] for o in only):
            continue
        r = measure(e)
        results[e['name']] = {**e, **r}
        print(f"{e['name']:28s} blk10 {r['blk10']:6.2f} temp {r['temporal']:6.2f} whole {r['whole']:6.2f} "
              f"tout {r['tout']:.4f} | esf {r['esf']:6.2f} ({r['esf_over']:5.1f}/{r['esf_under']:5.1f}, "
              f"{r['esf_edges']}) vcg {r['vcg']:.3f}", flush=True)
        json.dump(results, open(path, 'w'), indent=1)


if __name__ == '__main__':
    main()
