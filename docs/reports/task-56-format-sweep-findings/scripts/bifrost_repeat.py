#!/usr/bin/env python3
"""Task #56 F6: Bifrost v3.0 leaves chroma outside whole 4x4 blocks
uninitialised, so its output differs run to run at some frame sizes.

Each run is a fresh vspipe process (fresh memory), rendering every frame of
Bifrost (luma_thresh 10, variation 5, the template's call) on a synthetic
8-bit clip, and hashing the output's planes. The same size is run [--runs]
times unpadded and through plugin_formats.run_within('bifrost.Bifrost'),
which pads to the contract's width_step 4 / height_step 8. The table lists the
number of distinct hashes: 1 means deterministic.

    bifrost_repeat.py --deps <deps/macos-arm64> [--runs 3]

Limits: synthetic content (a moving gradient with a per-frame pattern), one
machine; uninitialised memory may happen to repeat, so "1" over three runs is
evidence, not proof (the source, bifrost.c, is the proof: chroma is written
only in whole blocks).
"""
import argparse
import os
import subprocess
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..'))
TEMPLATES = os.path.join(REPO, 'worker', 'templates')

SCRIPT = r'''
import hashlib, sys
sys.path.insert(0, {templates!r})
import vapoursynth as vs
import plugin_formats as _pf
core = vs.core
W, H, FMT, FIELD, GUARD = {w}, {h}, vs.{fmt}, {field}, {guard}
g = core.std.BlankClip(width=W, height=H, format=vs.GRAYS, length=6)
expr = 'X {{w}} / Y {{h}} / + 0.5 * N 0.05 * + X N + 2 % 0.1 * + 1 min'.replace('{{w}}', str(W)).replace('{{h}}', str(H))
g = core.akarin.Expr(g, expr) if hasattr(core, 'akarin') else core.std.Expr(g, 'x')
c = core.resize.Bicubic(core.std.ShufflePlanes([g, g, g], [0, 0, 0], vs.YUV), format=FMT, matrix_in_s='709', matrix_s='709')
c = core.std.SetFieldBased(c, FIELD)
fn = lambda x: core.bifrost.Bifrost(x, luma_thresh=10.0, variation=5, interlaced=FIELD > 0)
out = _pf.run_within(c, 'bifrost.Bifrost', fn) if GUARD else fn(c)
h = hashlib.md5()
for n in range(out.num_frames):
    f = out.get_frame(n)
    for p in range(f.format.num_planes):
        h.update(bytes(f[p]))
print('MD5 ' + h.hexdigest(), file=sys.stderr)
core.std.BlankClip(length=1).set_output()
'''


def run(deps, w, h, fmt, field, guard):
    with tempfile.NamedTemporaryFile('w', suffix='.vpy', delete=False) as f:
        f.write(SCRIPT.format(templates=TEMPLATES, w=w, h=h, fmt=fmt, field=field, guard=int(guard)))
        path = f.name
    try:
        r = subprocess.run([os.path.join(deps, 'vapoursynth', 'vspipe'), '-i', path, '-'],
                           capture_output=True, text=True, timeout=300)
    finally:
        os.unlink(path)
    for line in r.stderr.splitlines():
        if line.startswith('MD5 '):
            return line.split()[1]
    return 'error: ' + (r.stderr.strip().splitlines() or ['?'])[-1][:120]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--deps', required=True)
    ap.add_argument('--runs', type=int, default=3)
    a = ap.parse_args()
    print('size\tformat\tfield\tguard\tdistinct_md5s\truns')
    for (w, h) in ((96, 64), (98, 64), (720, 486), (96, 68)):
        for fmt in ('YUV420P8', 'YUV422P8', 'YUV444P8'):
            for field in (0, 2):
                if fmt == 'YUV420P8' and h % 4 == 2:
                    continue  # 4:2:0 at 486 lines is task #57's
                for guard in (False, True):
                    md5s = [run(a.deps, w, h, fmt, field, guard) for _ in range(a.runs)]
                    bad = [m for m in md5s if m.startswith('error')]
                    print('%dx%d\t%s\t%s\t%s\t%s\t%d' % (
                        w, h, fmt, 'tff' if field else 'prog', 'yes' if guard else 'no',
                        bad[0] if bad else len(set(md5s)), a.runs), flush=True)


if __name__ == '__main__':
    main()
