"""Run the real worker (`vapourbox-worker --detect-noise-halo`) on every
fixture and on the full-length real clips, and check it against the NumPy
reference measured on the same frame pairs: $SCRATCH/fx/parity.json.

Needs a worker build (`cd worker && cargo build`); $WORKER overrides the path.
"""
import json
import os
import subprocess
import tempfile
import time

import numpy as np

import probelib as L

FX = L.scratch('fx')
WORKER = os.environ.get('WORKER', os.path.join(L.REPO, 'worker', 'target', 'debug', 'vapourbox-worker'))


def run_worker(path, interlaced, frames=None):
    w, h, pix = L.probe(path)
    rate = subprocess.run([L.FFPROBE, '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                           'stream=r_frame_rate:format=duration', '-of', 'json', path],
                          capture_output=True, text=True, check=True).stdout
    info = json.loads(rate)
    num, den = info['streams'][0]['r_frame_rate'].split('/')
    fps = float(num) / float(den)
    total = frames or int(float(info['format']['duration']) * fps)
    job = {
        'id': '00000000-0000-0000-0000-000000000000', 'inputPath': path, 'outputPath': '/dev/null',
        'qtgmcParameters': {}, 'encodingSettings': {}, 'inputWidth': w, 'inputHeight': h,
        'inputPixelFormat': pix, 'inputFrameRate': fps, 'totalFrames': total,
        'detectedFieldOrder': 'tff' if interlaced else 'progressive',
    }
    with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as f:
        json.dump(job, f)
        cfg = f.name
    t = time.monotonic()
    r = subprocess.run([WORKER, '--detect-noise-halo', '--config', cfg], capture_output=True, text=True)
    elapsed = time.monotonic() - t
    os.remove(cfg)
    line = [ln for ln in r.stdout.splitlines() if ln.startswith('{')][-1]
    return json.loads(line), elapsed


def main():
    manifest = json.load(open(os.path.join(FX, 'manifest.json')))
    out = {}
    worst = {'noise': 0.0, 'halo': 0.0}
    for e in manifest:
        rep, secs = run_worker(e['path'], e['interlaced'], frames=8)
        frames = L.luma(e['path'], 0, 8)
        pairs = [(frames[f], frames[f + 1]) for f in sorted(set(rep['frames'])) if f + 1 < len(frames)]
        ref = L.final_source(pairs, e['interlaced'])
        dn = None if rep['noise'] is None or ref['noise'] is None else abs(rep['noise'] - ref['noise'])
        dh = None if rep['halo'] is None or ref['halo'] is None else abs(rep['halo'] - ref['halo'])
        same = (rep['noiseHigh'] == ref['noise_high']) and (rep['haloHigh'] == ref['halo_high'])
        for k, d in (('noise', dn), ('halo', dh)):
            if d is not None:
                worst[k] = max(worst[k], d)
        out[e['name']] = dict(worker=rep, reference=ref, seconds=secs, same_verdict=same)
        print(f"{e['name']:28s} worker noise {rep['noise']} halo {rep['halo']} | ref noise {ref['noise']} "
              f"halo {ref['halo']} | {'same' if same else 'DIFFERENT'} {secs:.1f}s", flush=True)
    real = [
        ('vhs_full', os.path.join(L.RES, 'interlaced_test.avi'), True),
        ('dvbt_full', os.path.join(L.RES, 'pal-dvbt-fieldcoded-25i.ts'), True),
        ('small_clip_full', os.path.join(L.RES, 'small_clip.mp4'), False),
        ('nasa_partial', L.scratch('src', 'nasa.webm'), False),
        ('notld_partial', L.scratch('src', 'notld.webm'), False),
    ]
    for name, path, il in real:
        # The partial downloads hold only their first minutes.
        frames = None
        if 'partial' in name:
            frames = 60 * 24 if 'notld' in name else 60 * 60
        rep, secs = run_worker(path, il, frames=frames)
        out[name] = dict(worker=rep, seconds=secs)
        print(f'{name:28s} {json.dumps(rep)} {secs:.1f}s', flush=True)
    out['_worst'] = worst
    json.dump(out, open(os.path.join(FX, 'parity.json'), 'w'), indent=1)
    print('worst difference worker vs reference:', worst)
    print('verdicts that differ:', [n for n, v in out.items() if isinstance(v, dict) and v.get('same_verdict') is False])


if __name__ == '__main__':
    main()
