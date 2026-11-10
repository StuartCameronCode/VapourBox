"""Preview of frame 0 before and after the fix, compared with each other and
with frame 0 of an untrimmed lossless encode (the fix stops passing `-ss 0`
when the window starts at frame 0, matching the untrimmed encode, which never
seeks).

  python3 frame0_probe.py --before WORKER --after WORKER [source ...]"""
import os
import subprocess
import sys
from seeklib import FF, RES, WORK, probe
import make_variants
from worker_probe import job_for, mad

FIXTURES = ['small_clip.mp4', 'seek_timebase_2997.mov', 'interlaced_test.avi', 'colorize_test.mp4',
            'face_restore_test.mp4', 'prores422_10bit_telecine.mov', 'hard_telecine_test.avi',
            'soft_telecine_test.mkv', 'pal-dvbt-fieldcoded-25i.ts']


def preview_rgb(worker, src, s):
    r = subprocess.run([worker, '--config', job_for(src, s, os.path.join(WORK, 'x.mkv')),
                        '--preview', '--frame', '0'], capture_output=True, check=True)
    return rgb(['-f', 'png_pipe', '-i', '-'], r.stdout)


def rgb(args, stdin=None):
    return subprocess.run([FF, '-v', 'error', *args, '-frames:v', '1', '-f', 'rawvideo',
                           '-pix_fmt', 'rgb24', '-'], input=stdin, capture_output=True,
                          check=True).stdout


def main():
    a = sys.argv[1:]
    before, after = a[a.index('--before') + 1], a[a.index('--after') + 1]
    rest = [x for x in a if x not in ('--before', '--after', before, after)]
    paths = rest or [os.path.join(RES, f) for f in FIXTURES] + make_variants.build()
    for src in paths:
        s = probe(src)
        enc = os.path.join(WORK, 'full.mkv')
        if os.path.exists(enc):
            os.remove(enc)
        subprocess.run([after, '--config', job_for(src, s, enc, endFrame=4, totalFrames=5)],
                       capture_output=True, check=True)
        e0 = rgb(['-i', enc])
        b, f = preview_rgb(before, src, s), preview_rgb(after, src, s)
        print(f"{os.path.basename(src):30s} preview of frame 0 unchanged: {b == f}   "
              f"vs encode frame 0, mean abs diff: before {mad(b, e0):.2f}, after {mad(f, e0):.2f}")


if __name__ == '__main__':
    main()
