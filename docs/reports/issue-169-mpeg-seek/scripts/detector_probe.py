"""The detectors before and after the fix: --detect-noise-halo and
--detect-crop on the TS/PS fixtures. They sample frames across the source
through the same decoder as the preview, so before the fix every sample was a
GOP-late picture (or none, past the last keyframe).

  python3 detector_probe.py --before PATH --after PATH"""
import json
import os
import subprocess
import sys
import uuid
from seeklib import RES, WORK, probe, sequential

SOURCES = ['pal-dvbt-fieldcoded-25i.ts', 'seek_dvd_pal.mpg', 'seek_gop_late_video.ts']


def job(src):
    s = probe(src)
    fo = s.get('field_order') or ''
    j = {'id': str(uuid.uuid4()), 'inputPath': src, 'outputPath': os.path.join(WORK, 'x.mkv'),
         'qtgmcParameters': {'enabled': False}, 'encodingSettings': {},
         'inputFrameRate': s['fps'], 'inputWidth': s['width'], 'inputHeight': s['height'],
         'inputPixelFormat': s['pix_fmt'], 'totalFrames': len(sequential(src)),
         'detectedFieldOrder': 'tff' if fo in ('tt', 'tb') else 'bff' if fo in ('bb', 'bt') else 'progressive'}
    path = os.path.join(WORK, f'det_{j["id"]}.json')
    with open(path, 'w') as f:
        json.dump(j, f)
    return path


def run(worker, flag, src):
    r = subprocess.run([worker, '--config', job(src), flag], capture_output=True, text=True)
    try:
        return json.loads(r.stdout.strip().splitlines()[-1])
    except Exception:
        return {'error': r.stderr[-300:]}


def main():
    a = sys.argv[1:]
    workers = {a[i].lstrip('-'): a[i + 1] for i in range(0, len(a), 2)}
    for src in SOURCES:
        path = os.path.join(RES, src)
        for label in ('before', 'after'):
            n = run(workers[label], '--detect-noise-halo', path)
            c = run(workers[label], '--detect-crop', path)
            keep = {k: n.get(k) for k in ('frames', 'usablePairs', 'noise', 'halo', 'noiseHigh', 'haloHigh', 'error') if k in n}
            ck = {k: c.get(k) for k in ('usableFrames', 'crop', 'confidence', 'error') if k in c}
            print(f"{src} {label}\n  noise/halo {keep}\n  crop {ck}")


if __name__ == '__main__':
    main()
