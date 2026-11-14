"""Which source picture each path shows for frame N, before and after the fix.

  python3 frame_probe.py --before WORKER --after WORKER [--json out.json] [source ...]

For each source (default: the three late-video fixtures and the DVB-T clip)
and each worker, with every pass off:
  * preview   `--preview --frame N` (the Processed side), matched by mean
              absolute difference against every picture of the reference
              decode (scaled to 160 px, nearest neighbour); its index is
              reported with that MAD and the next-best one
  * before    the app's before-frame command for that worker's side
              (PreviewGenerator.beforeFrameArgs without / with the offset),
              hashed on raw luma
  * trim      a lossless FFV1 encode of frames TRIM_A..TRIM_B
  * untrimmed a lossless FFV1 encode of the whole source, with the frame
              count the app would send (its old / new formula)
Indices are positions in the reference: every stored picture once, in
presentation order, decoded from the start without a seek.
The workers must be debug builds (they find deps/ by searching upward)."""
import json
import os
import subprocess
import sys
import probe_lib
from probe_lib import (FF, RES, WORK, FIXTURES, DVBT, probe, sequential, indices, video_start,
                       before_frame_hash, job_file, run_worker, app_frame_count)

FRAMES = (0, 1, 24, 25, 26, 60)
TRIM_A, TRIM_B = 30, 59
SCALE = 'scale=160:-2:flags=neighbor,format=rgb24'


def rgb_frames(args, w=160):
    data = subprocess.run([FF, '-v', 'quiet', *args, '-vf', SCALE, '-f', 'rawvideo', '-'],
                          capture_output=True).stdout
    return data


def split(data, size):
    return [data[i:i + size] for i in range(0, len(data) - size + 1, size)]


def mad(a, b):
    step = 3
    idx = range(0, min(len(a), len(b)), step)
    return sum(abs(a[i] - b[i]) for i in idx) / len(idx)


def closest(img, refs):
    """The reference picture nearest to `img`, with the margin that makes the
    match meaningful: its MAD and the next-best MAD. (The preview's PNG goes
    through the worker's own RGB conversion, so the best MAD is not 0.)"""
    d = [mad(img, r) for r in refs]
    order = sorted(range(len(d)), key=d.__getitem__)
    return {'index': order[0], 'mad': round(d[order[0]], 2),
            'next_mad': round(d[order[1]], 2) if len(order) > 1 else None}


def preview_index(worker, src, s, n, refs):
    r = run_worker(worker, job_file(src, s, os.path.join(WORK, 'x.mkv')), '--preview', '--frame', str(n))
    if r.returncode or not r.stdout:
        return 'error'
    pv = os.path.join(WORK, 'pv.png')
    with open(pv, 'wb') as f:
        f.write(r.stdout)
    return closest(rgb_frames(['-i', pv]), refs)


def encode(worker, src, s, seq, **extra):
    out = os.path.join(WORK, 'enc.mkv')
    if os.path.exists(out):
        os.remove(out)
    r = run_worker(worker, job_file(src, s, out, **extra))
    if r.returncode or not os.path.exists(out):
        return {'error': r.stderr.decode(errors='replace')[-300:]}
    return {'frames': indices(sequential(out), seq)}


def fmt(p):
    if not isinstance(p, dict):
        return p
    return f"{p['index']} (MAD {p['mad']}, next {p['next_mad']})"


def summarise(idx, expect):
    if idx == expect:
        return f'{len(idx)} frames, exactly {expect[0]}..{expect[-1]}'
    head = idx[:6]
    return f'{len(idx)} frames, starts {head}, ends {idx[-3:]}'


def main():
    args = sys.argv[1:]
    workers, out = {}, None
    while args and args[0].startswith('--'):
        if args[0] in ('--before', '--after'):
            workers[args[0][2:]] = args[1]
        elif args[0] == '--json':
            out = args[1]
        args = args[2:]
    paths = args or [os.path.join(RES, f) for f in FIXTURES + [DVBT]]
    results = []
    for src in paths:
        s = probe(src)
        seq = sequential(src)
        last = len(seq) - 1
        size = len(rgb_frames(['-i', src, '-frames:v', '1']))
        refs = split(rgb_frames(['-apply_cropping', 'codec', '-i', src, '-map', '0:v:0',
                                 '-fps_mode', 'passthrough']), size)
        offset = video_start(src)
        r = {'source': os.path.basename(src), 'offset': round(offset, 6), 'stored': len(seq)}
        print(f"== {r['source']}: video starts {offset:.3f} s after the container, {len(seq)} pictures")
        for side, worker in workers.items():
            new = side == 'after'
            count = app_frame_count(src, new=new)
            row = {'app_count': count, 'frames': {}}
            for n in FRAMES + (last,):
                b = before_frame_hash(src, n, s['fps'], offset if new else 0.0, s['width'], s['height'])
                if new and n == 0:
                    # The app's frame 0 no longer seeks, like the worker's.
                    b = probe_lib.hashes(probe_lib._raw(['-apply_cropping', 'codec', '-i', src,
                                                         '-frames:v', '1', '-fps_mode', 'passthrough']),
                                         s['width'], s['height'])[0]
                row['frames'][n] = {'preview': preview_index(worker, src, s, n, refs),
                                    'before': indices([b], seq)[0] if b else 'error'}
            trim = encode(worker, src, s, seq, startFrame=TRIM_A, endFrame=TRIM_B,
                          totalFrames=TRIM_B - TRIM_A + 1)
            full = encode(worker, src, s, seq, totalFrames=count)
            row['trim'] = trim
            row['untrimmed'] = full
            r[side] = row
            print(f"  {side}: app counts {count} frames")
            for n, v in row['frames'].items():
                print(f"    frame {n:3d}: preview {fmt(v['preview'])}, before {v['before']}")
            for name, e, expect in (('trim', trim, list(range(TRIM_A, TRIM_B + 1))),
                                    ('untrimmed', full, list(range(len(seq))))):
                print(f"    {name}: {summarise(e['frames'], expect) if 'frames' in e else e['error']}")
        results.append(r)
    if out:
        with open(out, 'w') as f:
            json.dump(results, f, indent=1)


if __name__ == '__main__':
    main()
