"""Sources whose streams start together must come out exactly as before.

  python3 identity_probe.py --before WORKER --after WORKER

For every fixture in Tests/TestResources whose video starts with the
container (offset 0 by offset_probe.py's definition), with every pass off:
an untrimmed and a trimmed (10..40) FFV1 encode with the sound copied, and a
preview of frame 10. Each output is compared before vs after by framemd5 of
every stream (video and audio packets decoded) and the preview PNG's bytes.
A source with an offset is listed but skipped: it is meant to change."""
import os
import subprocess
import sys
from probe_lib import FF, RES, WORK, probe, video_start, job_file, run_worker

EXTS = ('.ts', '.mts', '.mp4', '.mov', '.mkv', '.avi', '.mpg')


def framemd5(path):
    r = subprocess.run([FF, '-v', 'error', '-i', path, '-map', '0', '-f', 'framemd5', '-'],
                       capture_output=True, text=True)
    return [l for l in r.stdout.splitlines() if not l.startswith('#')]


def outputs(worker, src, s, tag):
    res = {}
    for name, extra in (('untrimmed', {}), ('trimmed', {'startFrame': 10, 'endFrame': 40, 'totalFrames': 31})):
        out = os.path.join(WORK, f'id_{tag}_{name}.mkv')
        if os.path.exists(out):
            os.remove(out)
        r = run_worker(worker, job_file(src, s, out, encodingSettings={'audioMode': 'passthrough'}, **extra))
        res[name] = framemd5(out) if r.returncode == 0 and os.path.exists(out) else f'error {r.returncode}'
    r = run_worker(worker, job_file(src, s, os.path.join(WORK, 'x.mkv')), '--preview', '--frame', '10')
    res['preview'] = r.stdout if r.returncode == 0 else f'error {r.returncode}'
    return res


def main():
    args = sys.argv[1:]
    w = dict(zip(args[0::2], args[1::2]))
    before, after = w['--before'], w['--after']
    bad = 0
    for f in sorted(os.listdir(RES)):
        if not f.lower().endswith(EXTS) or f.startswith('late_video'):
            continue
        src = os.path.join(RES, f)
        try:
            s = probe(src)
        except Exception:
            continue
        off = video_start(src)
        if off > 0:
            print(f'{f:36s} offset {off:.3f}: skipped (meant to change)')
            continue
        b, a = outputs(before, src, s, 'b'), outputs(after, src, s, 'a')
        def verdict(k):
            if isinstance(b[k], str) or isinstance(a[k], str) or not b[k]:
                return 'ERROR'  # a failed or empty run proves nothing
            return 'identical' if b[k] == a[k] else 'DIFFERENT'
        same = {k: verdict(k) for k in b}
        bad += any(v != 'identical' for v in same.values())
        print(f'{f:36s} ' + '  '.join(f'{k} {v}' for k, v in same.items()))
    print('all identical' if not bad else f'{bad} source(s) differ')


if __name__ == '__main__':
    main()
