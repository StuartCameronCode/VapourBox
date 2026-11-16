#!/usr/bin/env python3
"""Does moving the guards onto run_within() change any output? (task #48)

Encodes the same jobs twice, losslessly (FFV1, Color Format "original"),
with the worker reading the templates from before the change and from after
it, and compares the decoded frames' MD5s. Every migrated pass is run alone
on every reachable format: {4:2:0, 4:2:2, 4:4:4} x {8, 10, 12, 16} bits,
progressive and TFF, plus 4:1:1 8-bit for the passes that had a 4:1:1 guard.

  identity.py --worker <vapourbox-worker> --old <templates dir> \
              --new <templates dir> --ffmpeg <ffmpeg> --work <dir under the repo>

--work must lie under the repository: a debug worker finds deps/ by searching
upward from its own location, and it reads the templates beside it.

The fixtures are 12 frames of the interlaced capture at 352x240 (480 lines
would be the same code; this keeps the run short), scaled by swscale straight
to each depth so the deeper ones carry real low bits. Exit status 1 on any
difference. Prints one line per job.
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..'))
FIXTURE = os.path.join(REPO, 'Tests', 'TestResources', 'interlaced_test.avi')
W, H, N = 352, 240, 12

FORMATS = [f'yuv{ss}p{"" if b == 8 else str(b) + "le"}'
           for ss in ('420', '422', '444') for b in (8, 10, 12, 16)]

# Each migrated pass alone, with the defaults the app sends.
PASSES = {
    'descratch': {'descratch': {'enabled': True}},
    'descratch-chroma': {'descratch': {'enabled': True, 'modeU': 1, 'modeV': 1}},
    'dedot': {'chromaFixes': {'enabled': True, 'applyDedot': True}},
    'decrawl': {'chromaFixes': {'enabled': True, 'applyDeCrawl': True}},
    'derainbow': {'chromaFixes': {'enabled': True, 'applyDeRainbow': True}},
    'bifrost': {'chromaFixes': {'enabled': True, 'applyBifrost': True}},
    'cnr4': {'chromaDenoise': {'enabled': True, 'method': 'cnr4'}},
    'removedirt': {'spotless': {'enabled': True, 'method': 'removeDirt'}},
    'flowfps': {'frameRate': {'enabled': True, 'method': 'flowFps', 'target': 'ntsc5994'}},
}
# The passes whose 4:1:1 guard was removed (the top-of-script rule covers it).
PASSES_411 = ['cnr4', 'removedirt', 'flowfps', 'descratch']


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw)


def fixture(ffmpeg, work, pix_fmt):
    path = os.path.join(work, f'src_{pix_fmt}.mkv')
    if not os.path.exists(path):
        run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', '-i', FIXTURE,
             '-frames:v', str(N), '-vf', f'scale={W}:{H}:interl=1', '-pix_fmt', pix_fmt,
             '-c:v', 'ffv1', '-an', path])
    return path


def job(src, out, pix_fmt, field, pipeline):
    pipe = {'deinterlace': {'enabled': False}, **pipeline}
    return {
        'id': str(uuid.uuid4()),
        'inputPath': src,
        'outputPath': out,
        'qtgmcParameters': {'enabled': False},
        'processingPipeline': pipe,
        'encodingSettings': {'codec': 'ffv1', 'container': 'mkv', 'audioMode': 'none'},
        'detectedFieldOrder': field,
        'totalFrames': N,
        'inputFrameRate': 29.97002997002997,
        'inputWidth': W,
        'inputHeight': H,
        'inputPixelFormat': pix_fmt,
    }


def frame_md5s(ffmpeg, path):
    r = run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-i', path, '-map', '0:v',
             '-f', 'framemd5', '-'])
    return [l.split(',')[-1].strip() for l in r.stdout.splitlines() if l and not l.startswith('#')]


def encode(runtime, work, tag, j):
    cfg = os.path.join(work, f'{tag}.json')
    with open(cfg, 'w') as fh:
        json.dump(j, fh)
    if os.path.exists(j['outputPath']):
        os.remove(j['outputPath'])
    p = subprocess.run([os.path.join(runtime, 'vapourbox-worker'), '--config', cfg],
                       capture_output=True, text=True)
    errors = [l for l in p.stdout.splitlines() if '"error"' in l]
    if p.returncode != 0 or not os.path.exists(j['outputPath']):
        return None, (errors[-1] if errors else p.stderr[-400:])[:400]
    return j['outputPath'], None


def main():
    ap = argparse.ArgumentParser()
    for a in ('--worker', '--old', '--new', '--ffmpeg', '--work'):
        ap.add_argument(a, required=True)
    ap.add_argument('--passes')
    a = ap.parse_args()
    work = os.path.abspath(a.work)
    os.makedirs(work, exist_ok=True)
    runtimes = {}
    for side, tdir in (('old', a.old), ('new', a.new)):
        rt = os.path.join(work, side)
        shutil.rmtree(rt, ignore_errors=True)
        os.makedirs(rt)
        shutil.copy2(a.worker, os.path.join(rt, 'vapourbox-worker'))
        shutil.copytree(tdir, os.path.join(rt, 'templates'))
        runtimes[side] = rt

    passes = a.passes.split(',') if a.passes else list(PASSES)
    cases = [(p, f, fo) for p in passes for f in FORMATS for fo in ('progressive', 'tff')]
    cases += [(p, 'yuv411p', fo) for p in passes if p in PASSES_411 for fo in ('progressive', 'tff')]
    same = differ = failed = 0
    controls = {}

    def control(pix_fmt, fo):
        # The same source through no pass, so a pass that changed nothing
        # cannot pass for a pass whose change was kept exactly.
        if (pix_fmt, fo) not in controls:
            tag = f'control_{pix_fmt}_{fo}'
            out, _ = encode(runtimes['new'], work, tag, job(fixture(a.ffmpeg, work, pix_fmt),
                            os.path.join(work, tag + '.mkv'), pix_fmt, fo, {}))
            controls[(pix_fmt, fo)] = out and hashlib.md5(
                '\n'.join(frame_md5s(a.ffmpeg, out)).encode()).hexdigest()
        return controls[(pix_fmt, fo)]
    for p, pix_fmt, fo in cases:
        src = fixture(a.ffmpeg, work, pix_fmt)
        md5 = {}
        err = {}
        for side, rt in runtimes.items():
            tag = f'{p}_{pix_fmt}_{fo}_{side}'
            out, e = encode(rt, work, tag, job(src, os.path.join(work, tag + '.mkv'), pix_fmt, fo, PASSES[p]))
            if out:
                md5[side] = hashlib.md5('\n'.join(frame_md5s(a.ffmpeg, out)).encode()).hexdigest()
            else:
                err[side] = e
        if err:
            # A job that fails both before and after is not a difference the
            # change made; one that fails on one side only is.
            status = 'BOTH FAIL' if len(err) == 2 else 'DIFFERS (fails %s)' % ','.join(err)
            if len(err) == 2:
                failed += 1
            else:
                differ += 1
            print(f'{status:22} {p:18} {pix_fmt:12} {fo:12} {list(err.values())[0]}')
            continue
        if md5['old'] == md5['new']:
            same += 1
            note = '  (no change from the source)' if md5['new'] == control(pix_fmt, fo) else ''
            print(f'{"identical":22} {p:18} {pix_fmt:12} {fo:12} {md5["new"]}{note}')
        else:
            differ += 1
            print(f'{"DIFFERS":22} {p:18} {pix_fmt:12} {fo:12} {md5["old"]} {md5["new"]}')
        sys.stdout.flush()
    print(f'\n{same} identical, {differ} different, {failed} failing before and after')
    return 1 if differ else 0


if __name__ == '__main__':
    sys.exit(main())
