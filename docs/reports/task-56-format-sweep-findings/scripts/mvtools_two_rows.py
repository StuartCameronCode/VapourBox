#!/usr/bin/env python3
"""Task #56 F9: MVTools' Compensate / Degrain divide by zero on a picture
exactly two block rows tall.

For each block size b, overlap o and frame size, this runs mv.Compensate and
mv.Degrain1 (b x o, delta 1) on a flat grey 4:2:0 clip, once as is
and once through plugin_formats.mvtools_blocks(), and reports:

  - how vspipe ended (exit status; 136 / -8 is SIGFPE), and
  - the largest luma difference from the input. On a flat clip every vector
    is zero, so a correct Compensate returns the input exactly; Degrain of
    identical frames too.

Usage (one bundle per run; the x86 bundle runs under Rosetta on Apple
Silicon, which is enough here: the fault is an integer `div`, not SIMD):

    mvtools_two_rows.py --deps <deps/macos-arm64> > arm64.tsv
    mvtools_two_rows.py --deps <deps/macos-x64> --arch x86_64 > x64.tsv

Limits: one synthetic flat clip per cell (the fault does not depend on the
picture: it is the block grid); macOS only as written (the vspipe wrapper);
Linux and Windows x86 are covered by the CI push gate's format sweep.
"""
import argparse
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..'))
TEMPLATES = os.path.join(REPO, 'worker', 'templates')

SCRIPT = r'''
import sys
sys.path.insert(0, {templates!r})
import vapoursynth as vs
import plugin_formats as _pf
core = vs.core
B, O, W, H, KIND, GUARD = {b}, {o}, {w}, {h}, {kind!r}, {guard}
src = core.std.BlankClip(format=vs.YUV420P8, width=W, height=H, length=5, color=[128, 128, 128])

def run(c):
    sup = core.mv.Super(c, pel=1)
    fw = core.mv.Analyse(sup, isb=False, blksize=B, overlap=O, delta=1)
    if KIND == 'compensate':
        return core.mv.Compensate(c, sup, fw)
    bw = core.mv.Analyse(sup, isb=True, blksize=B, overlap=O, delta=1)
    return core.mv.Degrain1(c, sup, bw, fw)

out = _pf.mvtools_blocks(src, run) if GUARD else run(src)
mx = 0
fo, fs = out.get_frame(2), src.get_frame(2)
po, ps = fo[0], fs[0]
for y in range(H):
    for x in range(W):
        mx = max(mx, abs(po[y, x] - ps[y, x]))
print('MAXABS %d' % mx, file=sys.stderr)
core.std.BlankClip(length=1).set_output()
'''


def cell(deps, arch, b, o, w, h, kind, guard):
    with tempfile.NamedTemporaryFile('w', suffix='.vpy', delete=False) as f:
        f.write(SCRIPT.format(templates=TEMPLATES, b=b, o=o, w=w, h=h, kind=kind, guard=int(guard)))
        path = f.name
    cmd = [os.path.join(deps, 'vapoursynth', 'vspipe'), '-i', path, '-']
    if arch:
        cmd = ['arch', '-' + arch] + cmd
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    finally:
        os.unlink(path)
    maxabs = next((l.split()[1] for l in r.stderr.splitlines() if l.startswith('MAXABS')), '-')
    return r.returncode, maxabs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--deps', required=True)
    ap.add_argument('--arch', default='')
    a = ap.parse_args()
    print('kind\tblksize\toverlap\twidth\theight\tnBlkX\tnBlkY\tguard\texit\tmax_abs_diff')

    def row(kind, b, o, w, h):
        for guard in (False, True):
            rc, mx = cell(a.deps, a.arch, b, o, w, h, kind, guard)
            print('%s\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%d\t%s' % (
                kind, b, o, w, h, (w - o) // (b - o), (h - o) // (b - o),
                'yes' if guard else 'no', rc, mx))
            sys.stdout.flush()

    for kind in ('compensate', 'degrain1'):
        for b, o in ((8, 2), (8, 4), (16, 4), (16, 8), (32, 8), (32, 16)):
            # Heights at the edges of one and two block rows, 96 wide.
            for h in sorted({2 * b - o - 2, 2 * b - o, 3 * b - 2 * o - 2, 3 * b - 2 * o, 64}):
                if h >= b and h % 2 == 0:
                    row(kind, b, o, 96, h)
    # Widths at the edge of one and two block columns, 128 tall.
    for b, o in ((16, 8), (32, 8), (32, 2)):
        for w in sorted({2 * b - o - 2, 2 * b - o, 3 * b - 2 * o}):
            if w >= b and w % 2 == 0:
                row('compensate', b, o, w, 128)

if __name__ == '__main__':
    main()
