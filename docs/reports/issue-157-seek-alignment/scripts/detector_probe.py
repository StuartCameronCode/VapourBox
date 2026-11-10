"""The detectors decode with the preview's decoder, so the fix reaches them.
Runs `--detect-noise-halo` and `--detect-crop` with the worker before and after
the fix and prints what changed. For the noise score, also counts how many of
the sampled pairs the old decoder delivered as the same picture twice (the
motion-compensated difference of such a pair is zero: no noise).

  python3 detector_probe.py --before WORKER --after WORKER [source ...]"""
import json
import os
import subprocess
import sys
from seeklib import FF, RES, WORK, probe, sequential, seek_decode
import make_variants
from worker_probe import job_for

FIXTURES = ['small_clip.mp4', 'seek_timebase_2997.mov', 'face_restore_test.mp4',
            'colorize_test.mp4', 'interlaced_test.avi', 'pal-dvbt-fieldcoded-25i.ts']


def detect(worker, flag, src, s, total):
    r = subprocess.run([worker, flag, '--config',
                        job_for(src, s, os.path.join(WORK, 'x.mkv'), totalFrames=total)],
                       capture_output=True, text=True)
    return json.loads(r.stdout.strip().splitlines()[-1])


def main():
    a = sys.argv[1:]
    before, after = a[a.index('--before') + 1], a[a.index('--after') + 1]
    rest = [x for x in a if x not in ('--before', '--after', before, after)]
    paths = rest or [os.path.join(RES, f) for f in FIXTURES] + make_variants.build()
    for src in paths:
        s = probe(src)
        total = len(sequential(src, 100000))
        nb, na = (detect(w, '--detect-noise-halo', src, s, total) for w in (before, after))
        same = sum(1 for f in nb.get('frames', [])
                   if len(set(seek_decode(src, f, 2, 'default'))) == 1)
        cb, ca = (detect(w, '--detect-crop', src, s, total) for w in (before, after))
        keys = ('crop', 'cropWithBars', 'confidence')
        print(f"{os.path.basename(src):28s} noise {nb.get('noise')} -> {na.get('noise')} "
              f"(high {nb.get('noiseHigh')} -> {na.get('noiseHigh')}; {same}/{len(nb.get('frames', []))} "
              f"old pairs were one picture twice)  halo {nb.get('halo')} -> {na.get('halo')}  "
              f"crop {'unchanged' if all(cb.get(k) == ca.get(k) for k in keys) else 'CHANGED'}"
              + ('' if all(cb.get(k) == ca.get(k) for k in keys) else
                 f" {[cb.get(k) for k in keys]} -> {[ca.get(k) for k in keys]}"))


if __name__ == '__main__':
    main()
