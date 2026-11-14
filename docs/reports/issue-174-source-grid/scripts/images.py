"""The report's images: frame 41 of an untrimmed encode of
soft_telecine_test.mkv (whose pictures carry their own "Frame n" counter),
before and after, beside the source's stored frame 41; and the Soft Telecine
method's output frames 0-9 at 23.976, before and after.

  python3 images.py --before WORKER --after WORKER
"""
import os
import subprocess
import sys
from gridlib import FF, WORK, HERE, resource, probe
from worker_probe import app_count
import json
import uuid

IMG = os.path.join(HERE, '..', 'img')


def encode(worker, path, p, total, deint):
    out = os.path.join(WORK, f'img_{uuid.uuid4().hex}.mkv')
    j = {'id': str(uuid.uuid4()), 'inputPath': path, 'outputPath': out,
         'qtgmcParameters': deint, 'processingPipeline': {'deinterlace': deint},
         'encodingSettings': {'codec': 'ffv1', 'container': 'mkv', 'audioMode': 'none'},
         'detectedFieldOrder': 'progressive', 'inputFrameRate': float(p['rate']),
         'inputWidth': p['w'], 'inputHeight': p['h'], 'totalFrames': total}
    cfg = os.path.join(WORK, f'img_{j["id"]}.json')
    json.dump(j, open(cfg, 'w'))
    subprocess.run([worker, '--config', cfg], capture_output=True, check=True)
    return out


def png(args, out):
    subprocess.run([FF, '-y', '-v', 'error', *args, out], check=True)


def main():
    a = sys.argv[1:]
    before, after = a[a.index('--before') + 1], a[a.index('--after') + 1]
    os.makedirs(IMG, exist_ok=True)
    src = resource('soft_telecine_test.mkv')
    p = probe(src)
    off = {'enabled': False}
    st = {'enabled': True, 'method': 'softTelecine'}
    b = encode(before, src, p, app_count(src, p, 'before'), off)
    f = encode(after, src, p, app_count(src, p, 'after'), off)
    pick = 'select=eq(n\\,41),scale=360:-2'
    for tag, path in (('source', src), ('before', b), ('after', f)):
        extra = ['-fps_mode', 'passthrough'] if tag == 'source' else []
        png(['-i', path, *extra, '-vf', pick, '-frames:v', '1'], os.path.join(WORK, f'f41_{tag}.png'))
    png(['-i', os.path.join(WORK, 'f41_source.png'), '-i', os.path.join(WORK, 'f41_before.png'),
         '-i', os.path.join(WORK, 'f41_after.png'), '-filter_complex', 'hstack=3'],
        os.path.join(IMG, 'frame41_source_before_after.png'))
    for tag, worker, app in (('before', before, 'before'), ('after', after, 'after')):
        out = encode(worker, src, p, app_count(src, p, app), st)
        png(['-i', out, '-vf', 'select=lt(n\\,10),scale=180:-2,tile=5x2', '-frames:v', '1'],
            os.path.join(IMG, f'soft_telecine_method_{tag}.png'))
    print('images written to', os.path.abspath(IMG))


if __name__ == '__main__':
    main()
