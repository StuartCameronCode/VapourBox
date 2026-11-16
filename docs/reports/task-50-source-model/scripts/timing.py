#!/usr/bin/env python3
"""Wall time of --probe-source per fixture, and of a preview with and without
the model (--source), median of N runs (task #50 report).

Usage: timing.py <worker> [runs] [old-worker]   (writes JSON to stdout)
old-worker: a build of the commit before task #50 (its preview runs the
old fill_* probes), for the "before" column.
Scratch files go to $VB_SCRATCH (default: the system temp directory).
"""
import json, os, statistics, subprocess, sys, tempfile, time, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(HERE, '..', '..', '..', '..', 'Tests', 'TestResources')
worker = sys.argv[1]
runs = int(sys.argv[2]) if len(sys.argv) > 2 else 5
old = sys.argv[3] if len(sys.argv) > 3 else None
scratch = os.environ.get('VB_SCRATCH', tempfile.gettempdir())
FIXTURES = ['small_clip.mp4', 'pal-dvbt-fieldcoded-25i.ts', 'seek_dvd_pal.mpg',
            'avi_h264_bframes.avi', 'soft_telecine_test.mkv', 'pal-sd-25.mov']


def timed(cmd):
    t = time.perf_counter()
    r = subprocess.run(cmd, capture_output=True)
    return time.perf_counter() - t, r


out = []
for f in FIXTURES:
    path = os.path.abspath(os.path.join(RES, f))
    probe = [timed([worker, '--probe-source', path])[0] for _ in range(runs)]
    model = subprocess.run([worker, '--probe-source', path], capture_output=True, text=True).stdout
    mpath = os.path.join(scratch, 'vb_model.json'); open(mpath, 'w').write(model)
    v = json.loads(model)['video']
    job = {"id": str(uuid.uuid4()), "inputPath": path, "outputPath": os.path.join(scratch, 'x.mkv'),
           "qtgmcParameters": {"enabled": False}, "encodingSettings": {},
           "inputFrameRate": v['frameRate'], "inputWidth": v['width'], "inputHeight": v['height'],
           "inputPixelFormat": v['pixelFormat'], "totalFrames": v['frameCount']}
    cfg = os.path.join(scratch, 'vb_job.json'); json.dump(job, open(cfg, 'w'))
    frame = str(min(40, v['frameCount'] - 1))
    bare = [timed([worker, '--preview', '--frame', frame, '--config', cfg])[0] for _ in range(runs)]
    given = [timed([worker, '--preview', '--frame', frame, '--config', cfg, '--source', mpath])[0]
             for _ in range(runs)]
    before = [timed([old, '--preview', '--frame', frame, '--config', cfg])[0]
              for _ in range(runs)] if old else [float('nan')]
    out.append({'file': f, 'probeSourceMs': round(statistics.median(probe) * 1000),
                'previewBeforeMs': round(statistics.median(before) * 1000) if old else None,
                'previewProbingMs': round(statistics.median(bare) * 1000),
                'previewWithModelMs': round(statistics.median(given) * 1000)})
json.dump(out, sys.stdout, indent=1)
