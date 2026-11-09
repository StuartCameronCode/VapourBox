"""How long `--detect-noise-halo` takes, with a release worker, on SD, 1080p,
1440x1080 10-bit AV1 and a 4K H.264 clip made from the NASA footage:
$SCRATCH/fx/timing.json. Each run three times; the median is reported.

WORKER=<path to a release build> (a release build finds deps in the app's
install location, not the repo's). Timings are one Apple M1 Pro; the measure
itself is single-threaded per pair, the pairs run in parallel.
"""
import json
import os
import subprocess

import numpy as np

import probelib as L
import worker_parity as P

FX = L.scratch('fx')


def main():
    uhd = L.scratch('fx', '_uhd.mp4')
    if not os.path.exists(uhd):
        subprocess.run([L.FFMPEG, '-v', 'error', '-y', '-ss', '50', '-t', '20', '-i', L.scratch('src', 'nasa.webm'),
                        '-vf', 'scale=3840:2160:flags=lanczos', '-c:v', 'libx264', '-preset', 'veryfast',
                        '-crf', '18', '-an', uhd], check=True)
    clips = [
        ('SD VHS (Lagarith 4:2:2, 79 frames)', os.path.join(L.RES, 'interlaced_test.avi'), True, None),
        ('SD DVB-T (H.264 4:2:0)', os.path.join(L.RES, 'pal-dvbt-fieldcoded-25i.ts'), True, None),
        ('1080p NASA (AV1 8-bit, first 60 s)', L.scratch('src', 'nasa.webm'), False, 60 * 60),
        ('1440x1080 NOTLD (AV1 10-bit, first 60 s)', L.scratch('src', 'notld.webm'), False, 60 * 24),
        ('2160p (H.264, 20 s)', uhd, False, None),
    ]
    out = {}
    for name, path, il, frames in clips:
        runs = [P.run_worker(path, il, frames=frames) for _ in range(3)]
        secs = float(np.median([s for _, s in runs]))
        rep = runs[0][0]
        out[name] = dict(seconds=secs, report=rep)
        print(f"{name:42s} {secs:5.1f} s  noise {rep.get('noise')} halo {rep.get('halo')} "
              f"pairs {rep.get('usablePairs')}/{len(rep.get('frames', []))}", flush=True)
    json.dump(out, open(os.path.join(FX, 'timing.json'), 'w'), indent=1)


if __name__ == '__main__':
    main()
