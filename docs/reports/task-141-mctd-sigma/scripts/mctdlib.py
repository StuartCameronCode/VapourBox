"""Shared helpers for task #141's MCTemporalDenoise probe.

Builds on issue #177's probe (../../issue-177-strength-mapping/scripts):
its probelib (worker, bundle and scoring helpers) and its fixtures
(build_fixtures.py: cam / film / dvbt with AddGrain noise sigma 2/4/6/9;
probe_scd.py: the hard-cut fixture). Run that report's build_fixtures.py
first with the same $SCRATCH.

Every MCTD run goes through the worker with the Noise Reduction pass off and
the call in Custom VapourSynth, so it is the template's call plus the probed
arguments, encoded to lossless FFV1.
"""
import json
import os
import shutil
import subprocess
import sys
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', '..', 'issue-177-strength-mapping', 'scripts'))

import probelib  # noqa: E402
from probelib import compare, scratch, stream_info  # noqa: E402,F401

DATA = os.path.join(os.path.dirname(HERE), 'data')


def fixture(name, noise):
    """`<name>_n<noise>.mkv` from issue #177's fixtures; noise 0 is the clean clip."""
    d = os.path.join(os.environ['SCRATCH'], 'fixtures')
    if noise == 0:
        p = os.path.join(d, f'{name}_n0.mkv')
        if not os.path.exists(p):
            shutil.copy(os.path.join(d, f'{name}_clean.mkv'), p)
        return p
    return os.path.join(d, f'{name}_n{noise}.mkv')


def key(name, noise, args):
    return f'{name}|{noise}|' + ','.join(f'{k}={v}' for k, v in sorted(args.items()))


def run_mctd(src, args, out):
    """Encode `src` with haf.MCTemporalDenoise(clip, **args). Returns seconds."""
    info = stream_info(src)
    call = ', '.join(f'{k}={v!r}' for k, v in args.items())
    job = {
        'id': str(uuid.uuid4()), 'inputPath': src, 'outputPath': out,
        'qtgmcParameters': {'enabled': False},
        'processingPipeline': {'deinterlace': {'enabled': False}},
        'encodingSettings': {'codec': 'ffv1', 'container': 'mkv', 'audioMode': 'none',
                             'customVapoursynth': f'clip = haf.MCTemporalDenoise(clip, {call})'},
        'inputWidth': info['width'], 'inputHeight': info['height'],
        'inputPixelFormat': info['pix_fmt'], 'inputFrameRate': info['fps'],
        'totalFrames': info['frames'],
    }
    cfg = out + '.json'
    with open(cfg, 'w') as f:
        json.dump(job, f)
    t = time.time()
    r = subprocess.run([probelib.WORKER, '--config', cfg], capture_output=True, text=True,
                       env=probelib.env(), cwd=os.path.dirname(probelib.WORKER))
    secs = time.time() - t
    os.remove(cfg)
    if r.returncode != 0 or not os.path.exists(out):
        raise RuntimeError(f'{out}: {(r.stdout + r.stderr)[-1500:]}')
    return secs


def load(name):
    p = os.path.join(DATA, name)
    if not os.path.exists(p):
        return {}
    with open(p) as f:
        return json.load(f)


def save(name, obj):
    os.makedirs(DATA, exist_ok=True)
    with open(os.path.join(DATA, name), 'w') as f:
        json.dump(obj, f, indent=1, sort_keys=True)
        f.write('\n')
