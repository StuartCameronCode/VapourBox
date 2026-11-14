"""The report's images: the independent reference for a frame (left), what the
worker delivered for it before the fix (middle) and after (right), side by
side, top-left quarter (testsrc2's frame counter) at full resolution, into
../img/. "preview" shots are the processed preview of the frame; "trim" shots
are the first frame of a lossless trimmed encode starting there.

  python3 images.py --before OLD --after NEW"""
import argparse
import json
import os
import subprocess
import uuid
from avilib import FF, RES, WORK, probe
from worker_probe import encode

HERE = os.path.dirname(os.path.abspath(__file__))
IMG = os.path.join(HERE, '..', 'img')
SHOTS = [  # (file, kind, source, frame)
    ('01-mpeg2-avi-preview-43.png', 'preview', 'hard_telecine_test.avi', 43),
    ('02-mpeg2-avi-trim-from-2.png', 'trim', 'hard_telecine_test.avi', 2),
    ('03-ntsc-intra-trim-from-43.png', 'trim', 'avi_ntsc_intra.avi', 43),
    ('04-h264-avi-preview-41.png', 'preview', 'avi_h264_bframes.avi', 41),
]


def preview(worker, src, n):
    s = probe(src)
    j = {'id': str(uuid.uuid4()), 'inputPath': src, 'outputPath': os.path.join(WORK, 'x.mkv'),
         'qtgmcParameters': {'enabled': False}, 'processingPipeline': {'deinterlace': {'enabled': False}},
         'encodingSettings': {'codec': 'ffv1', 'container': 'mkv', 'audioMode': 'none'},
         'inputFrameRate': s['fps'], 'inputWidth': s['width'], 'inputHeight': s['height'],
         'inputPixelFormat': 'yuv420p'}
    cfg = os.path.join(WORK, f'img_{j["id"]}.json')
    with open(cfg, 'w') as f:
        json.dump(j, f)
    png = os.path.join(WORK, f'img_{j["id"]}.png')
    with open(png, 'wb') as f:
        subprocess.run([worker, '--config', cfg, '--preview', '--frame', str(n)],
                       stdout=f, stderr=subprocess.DEVNULL, check=True)
    return png


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--before', required=True)
    ap.add_argument('--after', required=True)
    a = ap.parse_args()
    os.makedirs(IMG, exist_ok=True)
    for name, kind, src_name, n in SHOTS:
        src = os.path.join(RES, src_name)
        if kind == 'preview':
            got = [preview(a.before, src, n), preview(a.after, src, n)]
        else:
            got = [encode(a.before, src, n, n + 3), encode(a.after, src, n, n + 3)]
        s = probe(src)
        # The top-left quarter holds testsrc2's moving counter and sweep.
        crop = f'crop={s["width"] // 2}:{s["height"] // 2}:0:0'
        subprocess.run([FF, '-y', '-v', 'error', '-i', src,
                        '-i', got[0], '-i', got[1],
                        '-filter_complex',
                        f'[0:v]select=eq(n\\,{n}),{crop},format=rgb24[r];'
                        f'[1:v]select=eq(n\\,0),{crop},format=rgb24[b];[2:v]select=eq(n\\,0),{crop},format=rgb24[a];'
                        '[r][b][a]hstack=inputs=3',
                        '-frames:v', '1', os.path.join(IMG, name)], check=True)
        print(os.path.join(IMG, name))


if __name__ == '__main__':
    main()
