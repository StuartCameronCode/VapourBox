"""Run the worker itself, before and after the fix, and name the source
picture each path delivers.

  python3 worker_probe.py --worker PATH --label before|after [--json out.json]

For each committed fixture and frame N, every pass off:
  * preview:  `--preview --frame N` (the Processed side)
  * original: the app's before-frame command (PreviewGenerator.beforeFrameArgs,
              mirrored: a plain seek for `before`, the seek plan for `after`)
Each picture is named by the closest frame (mean absolute difference of the
full-size grey picture, every 7th sample) of the sequential decode, searched
from N-5 to N+35, so a GOP overshoot shows as its size; 'none' if nothing was
produced. The grey of an RGB PNG is a few levels off the source's own luma,
so the distance to the right frame is not 0, only the smallest.
And a trimmed lossless encode: each output frame named by its index in the
sequential decode (MD5 of the luma plane).

Debug workers find deps by their usual search (repo deps/ upward, or the
installed bundle)."""
import json
import os
import subprocess
import sys
import uuid
from seeklib import FF, RES, WORK, probe, video_start, seek_plan, target, sequential, indices

FIXTURES = {
    'seek_dvd_pal.mpg': ([1, 10, 41, 47, 77, 145], (37, 52)),
    'seek_gop_late_video.ts': ([1, 10, 41, 49, 77, 141, 148], (37, 52)),
    'pal-dvbt-fieldcoded-25i.ts': ([10, 40, 58, 77, 117], (45, 60)),
    'late_video_gop.ts': ([10, 41, 49, 77, 95], (30, 59)),
    'small_clip.mp4': ([10, 41, 77], (41, 52)),
}


def thumb(args):
    out = subprocess.run([FF, '-v', 'error', *args, '-vf', 'format=gray',
                          '-f', 'rawvideo', '-'], capture_output=True).stdout
    return out


def thumbs_sequential(src, s):
    data = thumb(['-i', src, '-map', '0:v:0', '-fps_mode', 'passthrough'])
    n = s['width'] * s['height']
    return [data[i:i + n] for i in range(0, len(data) - n + 1, n)]


def mad(a, b):
    m = min(len(a), len(b))
    return sum(abs(a[i] - b[i]) for i in range(0, m, 7)) / max(len(range(0, m, 7)), 1)


def name(img, refs, n):
    if not img:
        return 'none'
    cands = range(max(0, n - 5), min(len(refs), n + 36))
    best = min(cands, key=lambda k: mad(img, refs[k]))
    return best


def job_for(src, s, out, **extra):
    j = {'id': str(uuid.uuid4()), 'inputPath': src, 'outputPath': out,
         'qtgmcParameters': {'enabled': False},
         'processingPipeline': {'deinterlace': {'enabled': False}},
         'encodingSettings': {'codec': 'ffv1', 'container': 'mkv', 'audioMode': 'none'},
         'inputFrameRate': s['fps'], 'inputWidth': s['width'], 'inputHeight': s['height'],
         'inputPixelFormat': s['pix_fmt']}
    j.update(extra)
    path = os.path.join(WORK, f'job_{j["id"]}.json')
    with open(path, 'w') as f:
        json.dump(j, f)
    return path


def original_args(src, n, s, plan):
    """PreviewGenerator.beforeFrameArgs with the video start offset (#168);
    with the seek plan only after the fix."""
    if n == 0:
        return ['-apply_cropping', 'codec', '-i', src], None
    t = target(n, s['fps'], video_start(src))
    if not plan:
        return ['-ss', f'{t:.6f}', '-apply_cropping', 'codec', '-i', src], None
    early = t - plan['preroll']
    pre = ['-copyts'] + (['-ss', f'{early:.6f}'] if early > 0 else [])
    return [*pre, '-apply_cropping', 'codec', '-i', src], f'trim=start={plan["container_start"] + t:.6f}'


def check(worker, label, src):
    s = probe(src)
    plan = seek_plan(src) if label == 'after' else None
    refs = thumbs_sequential(src, s)
    frames, (a, b) = FIXTURES[os.path.basename(src)]
    rows = []
    for n in frames:
        r = subprocess.run([worker, '--config', job_for(src, s, os.path.join(WORK, 'x.mkv')),
                            '--preview', '--frame', str(n)], capture_output=True)
        pv = os.path.join(WORK, 'pv.png')
        img = b''
        if r.returncode == 0 and r.stdout:
            with open(pv, 'wb') as f:
                f.write(r.stdout)
            img = thumb(['-i', pv])
        args, trim = original_args(src, n, s, plan)
        bf = os.path.join(WORK, 'orig.png')
        if os.path.exists(bf):
            os.remove(bf)
        vf = [trim] if trim else []
        subprocess.run([FF, '-y', '-v', 'error', *args, '-frames:v', '1',
                        *(['-vf', ','.join(vf)] if vf else []), bf])
        orig = thumb(['-i', bf]) if os.path.exists(bf) else b''
        rows.append({'frame': n, 'preview': name(img, refs, n), 'original': name(orig, refs, n)})
    out = os.path.join(WORK, f'trim_{uuid.uuid4().hex}.mkv')
    r = subprocess.run([worker, '--config', job_for(src, s, out, startFrame=a, endFrame=b,
                                                     totalFrames=b - a + 1)], capture_output=True)
    trim = None
    if r.returncode == 0 and os.path.exists(out):
        trim = indices(sequential(out), sequential(src))
        os.remove(out)
    return {'source': os.path.basename(src), 'rows': rows, 'trim': {'start': a, 'end': b, 'frames': trim}}


def main():
    args = sys.argv[1:]
    opts = {}
    while args and args[0].startswith('--'):
        opts[args[0]], args = args[1], args[2:]
    worker, label = opts['--worker'], opts['--label']
    results = []
    for f in FIXTURES:
        r = check(worker, label, os.path.join(RES, f))
        results.append(r)
        print(f"== {r['source']} ({label})")
        for row in r['rows']:
            ok = lambda v: 'ok' if v == row['frame'] else 'WRONG'
            print(f"  frame {row['frame']:3d}: preview {row['preview']} ({ok(row['preview'])}), "
                  f"original {row['original']} ({ok(row['original'])})")
        t = r['trim']
        want = list(range(t['start'], t['end'] + 1))
        print(f"  trim {t['start']}..{t['end']}: {t['frames']} {'ok' if t['frames'] == want else 'WRONG'}")
    if '--json' in opts:
        with open(opts['--json'], 'w') as f:
            json.dump(results, f, indent=1)


if __name__ == '__main__':
    main()
