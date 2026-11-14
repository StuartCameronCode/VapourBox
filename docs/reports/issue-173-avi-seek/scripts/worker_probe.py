"""Run the worker itself, before and after the fix, on the AVI fixtures, and
name the picture each path delivers by its index in a sequential decode.

  python3 worker_probe.py --before OLD --after NEW

  * preview of frame N (every pass off): the processed PNG against the
    sequential decode's N-2..N+2 (mean absolute difference, closest wins)
  * trimmed FFV1 encodes: every output frame named by MD5 of its luma
  * untrimmed FFV1 encode: the same, and whether the output is the source
  * untrimmed encodes of the non-AVI fixtures: framemd5 before = after

The workers must be debug builds that find deps/ by searching upward."""
import argparse
import hashlib
import json
import os
import subprocess
import uuid
from avilib import FF, RES, WORK, indices, probe, raw, sequential

AVIS = {'hard_telecine_test.avi': ([1, 2, 3, 10, 41, 43, 77], [(2, 13), (41, 52)]),
        'avi_h264_bframes.avi': ([1, 2, 3, 10, 41, 43, 77], [(2, 13), (41, 52)]),
        'avi_ntsc_intra.avi': ([1, 10, 41, 43, 77], [(43, 54)])}
CONTROLS = ['small_clip.mp4', 'seek_timebase_2997.mov', 'face_restore_test.mp4',
            'interlaced_test.avi', 'pal-sd-25.mov']


def job(src, out, **extra):
    s = probe(src)
    j = {'id': str(uuid.uuid4()), 'inputPath': src, 'outputPath': out,
         'qtgmcParameters': {'enabled': False},
         'processingPipeline': {'deinterlace': {'enabled': False}},
         'encodingSettings': {'codec': 'ffv1', 'container': 'mkv', 'audioMode': 'none'},
         'inputFrameRate': s['fps'], 'inputWidth': s['width'], 'inputHeight': s['height'],
         'inputPixelFormat': 'yuv420p'}
    j.update(extra)
    path = os.path.join(WORK, f'job_{j["id"]}.json')
    with open(path, 'w') as f:
        json.dump(j, f)
    return path


def rgb(args):
    # Passthrough timing: a `select`ed frame written as constant-rate
    # rawvideo comes out empty.
    out = subprocess.run([FF, '-v', 'error', *args, '-frames:v', '1', '-fps_mode', 'passthrough',
                          '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'],
                         capture_output=True, check=True).stdout
    if not out:
        raise RuntimeError(f'no frame from {args}')
    return out


def mad(a, b):
    return sum(abs(x - y) for x, y in zip(a[::7], b[::7])) / max(1, len(a[::7]))


def preview(worker, src, n):
    png = os.path.join(WORK, f'pv_{uuid.uuid4().hex}.png')
    with open(png, 'wb') as f:
        subprocess.run([worker, '--config', job(src, os.path.join(WORK, 'x.mkv')),
                        '--preview', '--frame', str(n)], stdout=f, stderr=subprocess.DEVNULL, check=True)
    got = rgb(['-i', png])
    diffs = {k: mad(got, rgb(['-i', src, '-vf', f'select=eq(n\\,{k})']))
             for k in range(max(0, n - 2), n + 3)}
    best = min(diffs, key=diffs.get)
    return best if diffs[best] < 0.5 else f'{best}?'


def encode(worker, src, start=None, end=None):
    out = os.path.join(WORK, f'enc_{uuid.uuid4().hex}.mkv')
    extra = {}
    if start is not None:
        extra = {'startFrame': start, 'endFrame': end, 'totalFrames': end - start + 1}
    else:
        extra = {'totalFrames': int(subprocess.run(
            [os.path.join(os.path.dirname(FF), 'ffprobe'), '-v', 'error', '-select_streams', 'v:0',
             '-count_frames', '-show_entries', 'stream=nb_read_frames', '-of', 'csv=p=0', src],
            capture_output=True, text=True).stdout.split()[0].strip(','))}
    subprocess.run([worker, '--config', job(src, out, **extra)], stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, check=True)
    return out


def framemd5(path):
    out = subprocess.run([FF, '-v', 'error', '-i', path, '-map', '0:v', '-f', 'framemd5', '-'],
                         capture_output=True, text=True).stdout
    return hashlib.md5('\n'.join(l for l in out.splitlines() if not l.startswith('#')).encode()).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--before', required=True)
    ap.add_argument('--after', required=True)
    a = ap.parse_args()
    for name, (frames, trims) in AVIS.items():
        src = os.path.join(RES, name)
        s = probe(src)
        seq = sequential(src)
        print(f'== {name}')
        for label, w in (('before', a.before), ('after', a.after)):
            pv = {n: preview(w, src, n) for n in frames}
            print(f'  {label:6s} preview (frame -> picture): {pv}')
            for st, en in trims:
                got = indices(raw(['-i', encode(w, src, st, en)], s['width'], s['height']), seq)
                print(f'  {label:6s} trim {st}..{en}: {got}')
            got = indices(raw(['-i', encode(w, src)], s['width'], s['height']), seq)
            print(f'  {label:6s} untrimmed: first {got[:5]} last {got[-3:]} '
                  f'({"= source" if got == list(range(len(seq))) else "differs from the source"})')
    print('== untrimmed encodes of the other fixtures, before vs after (framemd5)')
    for name in CONTROLS:
        src = os.path.join(RES, name)
        same = framemd5(encode(a.before, src)) == framemd5(encode(a.after, src))
        print(f'  {name}: {"identical" if same else "DIFFERENT"}')


if __name__ == '__main__':
    main()
