"""Issue #253: whole-job speed of the issue's chain, before and after.

The chain is the one the issue measured: SMDegrain, then LSFmod, then Colour
Correction with automatic white balance and local contrast (CLAHE), encoded
with x264 at CRF 10. Each job is run through the real worker binary
(`--config`), and the wall time from start to exit is divided into the frame
count. "Before" puts a copy of the old templates beside the worker
(`<worker dir>/templates`, the first place the worker looks), "after" runs the
repository's own; the copy is removed afterwards.

Source: `Tests/TestResources/pal-sd-25.mov` (720x576 ProRes, 125 frames),
looped, scaled to the issue's 706x480 and stored as 8-bit 4:2:0 FFV1, so
decoding costs little. It is a camera clip, not a VHS capture: the colour
correction does the same work on any picture, the denoiser and sharpener not
quite.

Usage (plain Python 3, no VapourSynth needed):
  python3 chain_timing.py <repo> <deps> <worker binary> <old templates dir> <scratch dir> [frames]
Prints one line per job: frames, seconds, fps. Runs each job twice and keeps
the faster run.
"""
import copy
import json
import os
import shutil
import subprocess
import sys
import time
import uuid

repo, deps, worker, old_templates, scratch = sys.argv[1:6]
frames = int(sys.argv[6]) if len(sys.argv) > 6 else 750
os.makedirs(scratch, exist_ok=True)
ffmpeg = os.path.join(deps, 'ffmpeg', 'ffmpeg')
fixture = os.path.join(scratch, f'chain_706x480_{frames}.mkv')
if not os.path.exists(fixture):
    subprocess.run([ffmpeg, '-v', 'error', '-y', '-stream_loop', '-1',
                    '-i', os.path.join(repo, 'Tests', 'TestResources', 'pal-sd-25.mov'),
                    '-vf', 'scale=706:480,format=yuv420p,setsar=1', '-frames:v', str(frames),
                    '-an', '-c:v', 'ffv1', fixture], check=True)

base = json.load(open(os.path.join(
    repo, 'docs', 'reports', 'task-122-vspipe-exit-hang', 'data', 'pitch-job.json')))
for key in ('inputWidth', 'inputHeight', 'inputPixelFormat', 'totalFrames',
            'inputFrameRate', 'source'):
    base[key] = None
base['detectedFieldOrder'] = 'progressive'
base['encodingSettings'].update({'codec': 'libx264', 'quality': 10, 'container': 'mkv',
                                 'encoderPreset': 'medium', 'maxCacheSizeMb': None})
pp = base['processingPipeline']
pp['stabilize']['enabled'] = False


def job(colour):
    j = copy.deepcopy(base)
    j['id'] = str(uuid.uuid4())
    j['inputPath'] = fixture
    j['outputPath'] = os.path.join(scratch, f'out_{j["id"]}.mkv')
    p = j['processingPipeline']
    p['noiseReduction'].update({'enabled': True, 'method': 'smDegrain'})
    p['sharpen'].update({'enabled': True, 'method': 'LSFmod'})
    if colour:
        p['colorCorrection'].update({'enabled': True, 'applyAutoWhiteBalance': True,
                                     'applyLocalContrast': True})
    return j


def run(j, templates=None):
    target = os.path.join(os.path.dirname(worker), 'templates')
    if templates:
        if os.path.exists(target):
            raise SystemExit(f'{target} exists; remove it first')
        shutil.copytree(templates, target)
    try:
        cfg = os.path.join(scratch, f'job_{j["id"]}.json')
        json.dump(j, open(cfg, 'w'))
        t = time.perf_counter()
        r = subprocess.run([worker, '--config', cfg], capture_output=True, text=True)
        dt = time.perf_counter() - t
        if r.returncode != 0:
            print(r.stdout[-3000:], r.stderr[-3000:])
            raise SystemExit(f'job failed ({r.returncode})')
        os.remove(j['outputPath'])
        return dt
    finally:
        if templates:
            shutil.rmtree(target)


rows = [
    ('SMDegrain + LSFmod', False, None),
    ('+ Colour Correction (auto WB + CLAHE), before', True, old_templates),
    ('+ Colour Correction (auto WB + CLAHE), after', True, None),
]
for label, colour, templates in rows:
    dt = min(run(job(colour), templates) for _ in range(2))
    print(f'{label:48s} {frames} frames {dt:7.1f} s {frames / dt:6.1f} fps', flush=True)
