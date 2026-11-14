"""The report's images: seek_gop_late_video.ts, frame 41, every pass off.
Source frame 41 (sequential decode), and the worker's preview and the app's
original before and after the fix, side by side at full size (320x240).

  python3 images.py --before PATH --after PATH"""
import os
import shutil
import subprocess
import sys
from seeklib import FF, RES, HERE, WORK, probe, seek_plan
from worker_probe import job_for, original_args

IMG = os.path.join(HERE, '..', 'img')
SRC = os.path.join(RES, 'seek_gop_late_video.ts')
N = 41


def png(args, out, vf=None):
    chain = ([vf] if vf else [])
    subprocess.run([FF, '-y', '-v', 'error', *args, '-frames:v', '1',
                    *(['-vf', ','.join(chain)] if chain else []), out], check=True)


def main():
    a = sys.argv[1:]
    workers = {a[i].lstrip('-'): a[i + 1] for i in range(0, len(a), 2)}
    os.makedirs(IMG, exist_ok=True)
    s = probe(SRC)
    png(['-i', SRC, '-map', '0:v:0'], os.path.join(IMG, '01-source-frame-41.png'),
        vf=f'select=eq(n\\,{N})')
    for i, label in enumerate(('before', 'after')):
        r = subprocess.run([workers[label], '--config', job_for(SRC, s, os.path.join(WORK, 'x.mkv')),
                            '--preview', '--frame', str(N)], capture_output=True, check=True)
        with open(os.path.join(IMG, f'0{2 + 2 * i}-preview-{label}.png'), 'wb') as f:
            f.write(r.stdout)
        args, trim = original_args(SRC, N, s, seek_plan(SRC) if label == 'after' else None)
        png(args, os.path.join(IMG, f'0{3 + 2 * i}-original-{label}.png'), vf=trim)
    for f in sorted(os.listdir(IMG)):
        print(os.path.join('img', f))


if __name__ == '__main__':
    main()
