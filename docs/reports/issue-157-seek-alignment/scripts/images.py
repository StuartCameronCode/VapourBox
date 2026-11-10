"""Screenshots for the report: small_clip.mp4 frame 41 as the app shows it.

  python3 images.py --before WORKER --after WORKER

Writes ../img/: the Original (the app's before frame), the Processed preview
from the worker before and after the fix (every pass off), and each preview's
difference from the Original, amplified 8x (black = identical)."""
import os
import subprocess
import sys
from seeklib import FF, RES, WORK, probe
from worker_probe import job_for, before_frame_args

IMG = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'img')
SRC = os.path.join(RES, 'small_clip.mp4')
FRAME = 41


def preview(worker, out):
    s = probe(SRC)
    r = subprocess.run([worker, '--config', job_for(SRC, s, os.path.join(WORK, 'x.mkv')),
                        '--preview', '--frame', str(FRAME)], capture_output=True, check=True)
    with open(out, 'wb') as f:
        f.write(r.stdout)


def scaled(src, out):
    """2x nearest-neighbour, so the pixels stay real."""
    subprocess.run([FF, '-y', '-v', 'error', '-i', src, '-vf', 'scale=iw*2:ih*2:flags=neighbor',
                    '-frames:v', '1', out], check=True)


def diff(a, b, out):
    subprocess.run([FF, '-y', '-v', 'error', '-i', a, '-i', b, '-filter_complex',
                    '[0:v]format=rgb24[x];[1:v]format=rgb24[y];[x][y]blend=all_mode=difference,'
                    'lutrgb=r=val*8:g=val*8:b=val*8,scale=iw*2:ih*2:flags=neighbor',
                    '-frames:v', '1', out], check=True)


def main():
    a = sys.argv[1:]
    before, after = a[a.index('--before') + 1], a[a.index('--after') + 1]
    os.makedirs(IMG, exist_ok=True)
    s = probe(SRC)
    orig = os.path.join(WORK, 'orig.png')
    subprocess.run([FF, '-v', 'error', *before_frame_args(SRC, FRAME, s['fps'], orig)], check=True)
    old, new = os.path.join(WORK, 'pv_old.png'), os.path.join(WORK, 'pv_new.png')
    preview(before, old)
    preview(after, new)
    scaled(orig, os.path.join(IMG, '01-original-frame-41.png'))
    scaled(old, os.path.join(IMG, '02-processed-before-fix.png'))
    scaled(new, os.path.join(IMG, '03-processed-after-fix.png'))
    diff(old, orig, os.path.join(IMG, '04-difference-before-fix.png'))
    diff(new, orig, os.path.join(IMG, '05-difference-after-fix.png'))
    print('wrote', sorted(os.listdir(IMG)))


if __name__ == '__main__':
    main()
