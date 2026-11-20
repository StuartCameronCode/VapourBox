#!/usr/bin/env python3
"""Every template path that reaches NNEDI3 without dh, run as a real job by
the worker on a 720x486 source (task #81), at 8 and 16-bit 4:2:0, with no
field order and TFF, encoded to FFV1. One JSON line per case: ok, or the
job's error.

  x86_paths.py WORKER SCRATCH [TEMPLATES]

WORKER is a vapourbox-worker debug build. For the x86 run that is an
x86_64-apple-darwin build run under Rosetta, which finds deps/macos-x64 by
the debug build's upward search (the macos-x64 bundle unzipped there).
TEMPLATES, when given, is copied to <worker dir>/templates, the first place
the worker looks, so it runs those templates (the "before"); without it any
copy there is removed and the worker uses worker/templates.
"""
import json
import os
import shutil
import subprocess
import sys
import uuid

worker, scratch = sys.argv[1], sys.argv[2]
templates = sys.argv[3] if len(sys.argv) > 3 else None
here = os.path.dirname(os.path.abspath(__file__))
repo = os.path.abspath(os.path.join(here, '..', '..', '..', '..'))
shadow = os.path.join(os.path.dirname(worker), 'templates')
if os.path.isdir(shadow):
    shutil.rmtree(shadow)
if templates:
    shutil.copytree(templates, shadow)

arch = 'macos-x64' if 'x86_64' in worker else 'macos-arm64'
ffmpeg = os.path.join(repo, 'deps', arch, 'ffmpeg', 'ffmpeg')
src = os.path.join(repo, 'Tests', 'TestResources', 'interlaced_test.avi')
os.makedirs(scratch, exist_ok=True)

CASES = {
    'bwdif_nnedi3': {'deinterlace': {'enabled': True, 'method': 'bwdif', 'bwdifEdeint': True, 'tff': True}},
    'bwdif_plain': {'deinterlace': {'enabled': True, 'method': 'bwdif', 'tff': True}},
    'daa': {'deinterlace': {'enabled': False}, 'antiAlias': {'enabled': True, 'method': 'daa'}},
    'mpeg2stinx': {'deinterlace': {'enabled': False}, 'deblock': {'enabled': True, 'method': 'mpeg2stinx'}},
}

for pf in ('yuv420p', 'yuv420p16le'):
    fixture = os.path.join(scratch, 'd1_%s.mkv' % pf)
    if not os.path.exists(fixture):
        subprocess.run([ffmpeg, '-v', 'error', '-y', '-i', src, '-frames:v', '12',
                        '-vf', 'scale=720:486:interl=1,format=' + pf, '-c:v', 'ffv1', '-an', fixture],
                       check=True)
    for name, pipeline in CASES.items():
        for order in (None, 'tff'):
            job = {'id': str(uuid.uuid4()), 'inputPath': fixture,
                   'outputPath': os.path.join(scratch, 'out_%s_%s_%s.mkv' % (name, pf, order)),
                   'qtgmcParameters': pipeline['deinterlace'],
                   # FFV1: x264 refuses an interlaced 720x486 picture by itself (#92).
                   'encodingSettings': {'codec': 'ffv1'},
                   'processingPipeline': pipeline}
            if order:
                job['detectedFieldOrder'] = order
            cfg = os.path.join(scratch, 'job.json')
            with open(cfg, 'w') as fh:
                json.dump(job, fh)
            p = subprocess.run([worker, '--config', cfg], capture_output=True, text=True, timeout=1800)
            result = 'ok'
            for line in p.stdout.splitlines():
                try:
                    m = json.loads(line)
                except ValueError:
                    continue
                if m.get('type') == 'error':
                    msg = m['message']
                    first = [l for l in msg.splitlines() if 'Error' in l or 'error' in l or 'failed' in l]
                    result = (first[-1] if first else msg.splitlines()[0]).strip()[:160]
                if m.get('type') == 'complete' and not m.get('success') and result == 'ok':
                    result = 'failed'
            print(json.dumps({'case': name, 'format': pf, 'field_order': order or 'none',
                              'templates': 'given' if templates else 'worktree', 'result': result}),
                  flush=True)
if os.path.isdir(shadow):
    shutil.rmtree(shadow)
