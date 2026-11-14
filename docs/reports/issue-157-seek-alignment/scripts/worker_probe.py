"""Run the worker itself, before and after the fix, and check which source
picture each path delivers.

  python3 worker_probe.py --worker PATH [--json out.json] [source ...]

For each source and frame N, with every pass off:
  * preview:  `--preview --frame N` (the Processed side)
  * before:   the app's own before-frame command (PreviewGenerator.beforeFrameArgs,
              mirrored here; PNG output instead of JPEG so nothing is lossy)
  * each is compared (mean absolute RGB difference) with the sequential decode's
    frames N-2..N+2 (`select=eq(n,N)`, image2 = passthrough timing); the
    closest offset is reported. 0 = the right frame.
And one trimmed lossless encode (FFV1/MKV, frames START..END): each output
frame is named by its index in the sequential decode (MD5 of the luma plane).

The worker must be a debug build so it finds deps/ by searching upward."""
import json
import os
import subprocess
import sys
import uuid
from seeklib import FF, RES, WORK, probe, sequential, indices

OFFSETS = (-2, -1, 0, 1, 2)


def rgb(args, tag, pre=None):
    # One -vf only: ffmpeg honours just the last, so a selecting filter goes
    # in front of the scale in the same chain.
    dst = os.path.join(WORK, f'{tag}.rgb')
    chain = ','.join(([pre] if pre else []) + ['scale=320:-2:flags=neighbor', 'format=rgb24'])
    subprocess.run([FF, '-y', '-v', 'error', *args, '-vf', chain,
                    '-frames:v', '1', '-f', 'rawvideo', dst], check=True)
    with open(dst, 'rb') as f:
        return f.read()


def mad(a, b):
    n = min(len(a), len(b))
    step = 5
    return sum(abs(a[i] - b[i]) for i in range(0, n, step)) / len(range(0, n, step))


def job_for(src, s, out, **extra):
    fo = s.get('field_order') or ''
    order = 'tff' if fo in ('tt', 'tb') else 'bff' if fo in ('bb', 'bt') else 'progressive'
    j = {'id': str(uuid.uuid4()), 'inputPath': src, 'outputPath': out,
         'qtgmcParameters': {'enabled': False},
         'processingPipeline': {'deinterlace': {'enabled': False}},
         'encodingSettings': {'codec': 'ffv1', 'container': 'mkv', 'audioMode': 'none'},
         'detectedFieldOrder': order, 'inputFrameRate': s['fps'],
         'inputWidth': s['width'], 'inputHeight': s['height'], 'inputPixelFormat': s['pix_fmt']}
    j.update(extra)
    path = os.path.join(WORK, f'job_{j["id"]}.json')
    with open(path, 'w') as f:
        json.dump(j, f)
    return path


def before_frame_args(src, n, fps, out):
    """PreviewGenerator.beforeFrameArgs, verbatim but for the output name."""
    ss = max(0.0, (n - 0.5) / fps)
    return ['-y', '-ss', f'{ss:.6f}', '-apply_cropping', 'codec', '-i', src,
            '-frames:v', '1', '-q:v', '2', out]


def check_frame(worker, src, s, n):
    pv = os.path.join(WORK, 'pv.png')
    r = subprocess.run([worker, '--config', job_for(src, s, os.path.join(WORK, 'x.mkv')),
                        '--preview', '--frame', str(n)], capture_output=True)
    if r.returncode or not r.stdout:
        return {'frame': n, 'error': r.stderr.decode(errors='replace')[-400:]}
    with open(pv, 'wb') as f:
        f.write(r.stdout)
    bf = os.path.join(WORK, 'before.png')
    subprocess.run([FF, '-v', 'error', *before_frame_args(src, n, s['fps'], bf)], check=True)
    got = {'preview': rgb(['-i', pv], 'pv'), 'before': rgb(['-i', bf], 'bf')}
    refs = {k: rgb(['-i', src, '-fps_mode', 'passthrough'], f'g{k}',
                   pre=f'select=eq(n\\,{n + k})')
            for k in OFFSETS if n + k >= 0}
    row = {'frame': n}
    for name, img in got.items():
        d = {k: round(mad(img, ref), 2) for k, ref in refs.items()}
        row[name] = d
        row[name + '_best'] = min(d, key=d.get)
    row['preview_vs_before'] = round(mad(got['preview'], got['before']), 2)
    return row


def check_trim(worker, src, s, start, end):
    out = os.path.join(WORK, f'trim_{uuid.uuid4().hex}.mkv')
    r = subprocess.run([worker, '--config', job_for(src, s, out, startFrame=start, endFrame=end,
                                                     totalFrames=end - start + 1)],
                       capture_output=True)
    if r.returncode or not os.path.exists(out):
        return {'start': start, 'end': end, 'error': r.stderr.decode(errors='replace')[-400:]}
    got = sequential(out, 100000)
    seq = sequential(src, end + 20)
    idx = indices(got, seq)
    os.remove(out)
    return {'start': start, 'end': end, 'frames': idx, 'ok': idx == list(range(start, end + 1))}


DEFAULT = ['small_clip.mp4', 'seek_timebase_2997.mov', 'interlaced_test.avi', 'colorize_test.mp4']


def main():
    args = sys.argv[1:]
    worker, out = None, None
    while args and args[0].startswith('--'):
        if args[0] == '--worker':
            worker, args = args[1], args[2:]
        elif args[0] == '--json':
            out, args = args[1], args[2:]
    paths = args or [os.path.join(RES, f) for f in DEFAULT]
    results = []
    for src in paths:
        s = probe(src)
        r = {'source': os.path.basename(src), 'time_base': s['time_base'], 'frames': [],
             'trim': check_trim(worker, src, s, 41, 52)}
        for n in (10, 41, 60):
            r['frames'].append(check_frame(worker, src, s, n))
        results.append(r)
        print(f"== {r['source']} ({s['time_base']})")
        for row in r['frames']:
            if 'error' in row:
                print(f"  frame {row['frame']}: ERROR {row['error']}")
                continue
            print(f"  frame {row['frame']:3d}: preview is source frame N{row['preview_best']:+d} "
                  f"({row['preview']}), before is N{row['before_best']:+d}, "
                  f"preview vs before {row['preview_vs_before']}")
        t = r['trim']
        print(f"  trim {t['start']}..{t['end']}: {t.get('frames', t.get('error'))}  "
              f"{'OK' if t.get('ok') else 'WRONG'}")
    if out:
        with open(out, 'w') as f:
            json.dump(results, f, indent=1)


if __name__ == '__main__':
    main()
