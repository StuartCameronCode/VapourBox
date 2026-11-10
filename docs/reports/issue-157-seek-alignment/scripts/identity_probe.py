"""Untrimmed encodes must not change: the fix only touches decoders that seek.
Encodes each source untrimmed with the worker before and after the fix, FFV1,
and compares every decoded frame (ffmpeg's framemd5 of the video stream).

  python3 identity_probe.py --before WORKER --after WORKER"""
import os
import subprocess
import sys
from seeklib import FF, RES, WORK, probe
from worker_probe import job_for

CASES = [('small_clip.mp4', False), ('seek_timebase_2997.mov', False),
         ('interlaced_test.avi', False), ('interlaced_test.avi', True),
         ('soft_telecine_test.mkv', False)]


def framemd5(path):
    out = subprocess.run([FF, '-v', 'error', '-i', path, '-map', '0:v:0', '-f', 'framemd5', '-'],
                         capture_output=True, text=True, check=True).stdout
    return [l.split(',')[-1].strip() for l in out.splitlines() if l and not l.startswith('#')]


def encode(worker, src, qtgmc, tag):
    s = probe(src)
    out = os.path.join(WORK, f'ident_{tag}.mkv')
    if os.path.exists(out):
        os.remove(out)
    extra = {}
    if qtgmc:
        q = {'enabled': True, 'preset': 'Super Fast', 'tff': True}
        extra = {'qtgmcParameters': q, 'processingPipeline': {'deinterlace': q}}
    r = subprocess.run([worker, '--config', job_for(src, s, out, **extra)], capture_output=True)
    if r.returncode:
        raise SystemExit(r.stderr.decode(errors='replace')[-800:])
    return framemd5(out)


def main():
    a = sys.argv[1:]
    before, after = a[a.index('--before') + 1], a[a.index('--after') + 1]
    for name, qtgmc in CASES:
        src = os.path.join(RES, name)
        b, f = encode(before, src, qtgmc, 'b'), encode(after, src, qtgmc, 'a')
        print(f"{name:26s} {'QTGMC' if qtgmc else 'no passes':9s} {len(b)} frames  "
              f"identical: {b == f}")


if __name__ == '__main__':
    main()
