#!/usr/bin/env python3
"""Is a pass deterministic? Runs one job written by identity.py N times with
each side's runtime and prints the hash of each run's frame MD5s (task #48:
RemoveDirt differed before vs after the change, and differs run to run on
either side).

  repeat.py --work <identity.py's --work dir> --ffmpeg <ffmpeg> \
            --job removedirt_yuv420p_progressive [--runs 9]
"""
import argparse
import collections
import hashlib
import json
import os
import subprocess


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--work', required=True)
    ap.add_argument('--ffmpeg', required=True)
    ap.add_argument('--job', required=True)
    ap.add_argument('--runs', type=int, default=9)
    a = ap.parse_args()
    work = os.path.abspath(a.work)
    seen = {}
    for i in range(a.runs):
        for side in ('old', 'new'):
            with open(os.path.join(work, f'{a.job}_{side}.json')) as fh:
                j = json.load(fh)
            j['outputPath'] = os.path.join(work, f'{a.job}_{side}_r{i}.mkv')
            j['id'] = j['id'][:-4] + '%04d' % i
            cfg = os.path.join(work, f'repeat_{side}_{i}.json')
            with open(cfg, 'w') as fh:
                json.dump(j, fh)
            if os.path.exists(j['outputPath']):
                os.remove(j['outputPath'])
            subprocess.run([os.path.join(work, side, 'vapourbox-worker'), '--config', cfg],
                           capture_output=True)
            r = subprocess.run([a.ffmpeg, '-loglevel', 'error', '-i', j['outputPath'], '-f', 'framemd5', '-'],
                               capture_output=True, text=True)
            frames = [l.split(',')[-1].strip() for l in r.stdout.splitlines() if l and not l.startswith('#')]
            h = hashlib.md5('\n'.join(frames).encode()).hexdigest()
            seen.setdefault(side, []).append(h)
            print(side, i, h, flush=True)
    for side, hs in seen.items():
        c = collections.Counter(hs)
        common = c.most_common(1)[0][1]
        print(f'{side}: {len(c)} distinct results in {len(hs)} runs; {len(hs) - common} differ from the most common')


if __name__ == '__main__':
    main()
