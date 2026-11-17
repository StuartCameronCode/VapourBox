"""Which output samples of an MVTools call a frame never writes (task #66).

VapourSynth recycles frame buffers. Fill the pool with value A and render the
call; fill it with B and render a fresh copy of the graph. A sample the call
wrote is the same both times; one it left alone is A, then B. Pure Python: no
numpy in the deps bundle.

  unwritten.py <call> [WxH ...]
"""
import math
import random
import sys

import vapoursynth as vs

core = vs.core
core.num_threads = int(__import__('os').environ.get('THREADS', '1'))


def plane_list(f, p):
    m = f[p]
    return m.tolist() if hasattr(m, 'tolist') else memoryview(m).tolist()


def source(w, h, fmt):
    c = core.std.BlankClip(width=w, height=h, format=fmt, length=8)
    peak = (1 << c.format.bits_per_sample) - 1

    def fill(n, f):
        fo = f.copy()
        r = random.Random(n)
        for p in range(fo.format.num_planes):
            m = fo[p]
            ph, pw = m.shape
            for y in range(ph):
                for x in range(pw):
                    v = (math.sin((x + 3 * n) / 5.0) + math.cos(y / 7.0)) * peak / 5 + peak / 2
                    m[y, x] = max(0, min(peak, int(v + r.gauss(0, peak / 40))))
        return fo
    return core.std.ModifyFrame(c, c, fill)


def degrain(c):
    sup = core.mv.Super(c, pel=1)
    bv = core.mv.Analyse(sup, isb=True, blksize=32, overlap=8)
    fv = core.mv.Analyse(sup, isb=False, blksize=32, overlap=8)
    return core.mv.Degrain1(c, sup, bv, fv)


def degrain16(c):
    sup = core.mv.Super(c, pel=1)
    bv = core.mv.Analyse(sup, isb=True, blksize=16, overlap=8)
    fv = core.mv.Analyse(sup, isb=False, blksize=16, overlap=8)
    return core.mv.Degrain1(c, sup, bv, fv)


def compensate(c):
    sup = core.mv.Super(c, pel=1)
    fv = core.mv.Analyse(sup, isb=False, blksize=32, overlap=8)
    return core.mv.Compensate(c, sup, fv)


def qtgmc_draft(c):
    import havsfunc as haf
    return haf.QTGMC(core.std.SetFieldBased(c, 0), Preset='Draft', TFF=True)


def qtgmc_draft_same(c):
    """Control: the same fill twice must give the same picture."""
    return qtgmc_draft(c)


CALLS = {'qtgmc_draft': qtgmc_draft, 'qtgmc_draft_same': qtgmc_draft_same, 'degrain': degrain, 'degrain16': degrain16, 'compensate': compensate}


def render(fill, w, h, fmt, call):
    pol = core.std.BlankClip(width=w, height=h, format=fmt, length=48, color=[fill] * 3)
    pol = core.std.Expr(pol, 'x 0 +')
    for n in range(48):
        pol.get_frame(n)
    f = call(source(w, h, fmt)).get_frame(3)
    return [plane_list(f, p) for p in range(f.format.num_planes)]


def main():
    call = CALLS[sys.argv[1]]
    sizes = [tuple(map(int, s.split('x'))) for s in sys.argv[2:]] or [(96, 96), (98, 96), (100, 96), (104, 96), (98, 64)]
    for (w, h) in sizes:
        for fmt in (vs.YUV420P8, vs.YUV420P12, vs.YUV422P8, vs.YUV444P16):
            ff = core.get_video_format(fmt)
            peak = (1 << ff.bits_per_sample) - 1
            a = render(0, w, h, fmt, call)
            b = render(0 if sys.argv[1].endswith('_same') else peak, w, h, fmt, call)
            msg = []
            for p, (pa, pb) in enumerate(zip(a, b)):
                bad = [(x, y) for y, (ra, rb) in enumerate(zip(pa, pb)) for x, (va, vb) in enumerate(zip(ra, rb)) if va != vb]
                if bad:
                    xs = [x for x, _ in bad]; ys = [y for _, y in bad]
                    msg.append('plane %d: %d samples x %d..%d y %d..%d' % (p, len(bad), min(xs), max(xs), min(ys), max(ys)))
            print('%-10s %4dx%-4d %-12s %s' % (sys.argv[1], w, h, ff.name, '; '.join(msg) or 'every sample written'), flush=True)


main()
