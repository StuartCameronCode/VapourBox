"""§3: decoders that start at frame N (preview window, trimmed encode,
detectors). Each start's first 10 frames, against the untrimmed grid decode's
slots N..N+9, for three recipes:

  old   the decoder before this fix: (N - 0.5)/fps seek + setpts=PTS-STARTPTS
        (#157), constant-rate output
  B     the same seek, then fps=<rate>: the grid untrimmed, but the reset still
        rebases to the first frame the seek kept
  grid  the fix: -copyts, seek LOOKBACK slots early, setpts to the first
        picture, fps, trim=start_pts=N, reset

  python3 seek_probe.py [--json out.json]
"""
import json
import sys
from gridlib import FIXTURES, resource, probe, stored, cfr_decode, grid_decode, name, hashes

STARTS = [1, 2, 3, 4, 5, 6, 10, 40, 41, 42, 43, 77, 98, 100, 102, 104, 105]
COUNT = 10


def b_decode(path, p, n):
    args, vf = [], []
    if n > 0:
        args = ['-ss', f'{(n - 0.5) / float(p["rate"]) + p["offset"]:.6f}']
        vf = ['setpts=PTS-STARTPTS']
    elif p['offset'] > 0:
        vf = ['setpts=PTS-STARTPTS']
    vf.append(f'fps={p["rate"].numerator}/{p["rate"].denominator}')
    return hashes(args + ['-apply_cropping', 'codec', '-i', path, '-map', '0:v:0',
                          '-vf', ','.join(vf), '-frames:v', str(COUNT)], p['w'], p['h'])


def main():
    rows = []
    for f in FIXTURES:
        path = resource(f)
        p = probe(path)
        if not p['has_pts'] or p['ts']:
            # No grid (packets without PTS: #173's), or a TS/PS whose old seek
            # also lands on the next keyframe (#169's): not this recipe's to judge.
            continue
        st = stored(path, p)
        ref = grid_decode(path, p)
        starts = [n for n in STARTS if n + COUNT <= len(ref)]
        ok = {'old': 0, 'B': 0, 'grid': 0}
        bad = []
        for n in starts:
            want = ref[n:n + COUNT]
            got = {'old': cfr_decode(path, p, n, COUNT), 'B': b_decode(path, p, n),
                   'grid': grid_decode(path, p, n, COUNT)}
            for k, v in got.items():
                ok[k] += v == want
            if any(v != want for v in got.values()):
                bad.append((n, name(want, st)[:5], {k: name(v, st)[:5] for k, v in got.items()}))
        rows.append(dict(file=f, starts=len(starts), **ok))
        print(f"{f:30s} starts {len(starts):2d}  old {ok['old']:2d}  B {ok['B']:2d}  grid {ok['grid']:2d}")
        for n, want, got in bad[:4]:
            print(f"   start {n}: want {want}  " + '  '.join(f'{k} {v}' for k, v in got.items()))
    if '--json' in sys.argv:
        json.dump(rows, open(sys.argv[sys.argv.index('--json') + 1], 'w'), indent=1)


if __name__ == '__main__':
    main()
