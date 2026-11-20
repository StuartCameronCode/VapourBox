# QTGMC's internal mv.Mask on a synthetic clip, for valgrind (task #79).
# vspipe -a call=qtgmc -a size=WxH -a fmt=<vs format name> \
#        [-a input_type=2|3] [-a blksize=32] [-a overlap=16] [-a preset=Slow] \
#        [-a guard=0|1] [-a templates=dir] mask.vpy -
#   call:  qtgmc  havsfunc's QTGMC, which runs mv.Mask(kind=1) on InputType
#                 2/3 at Placebo..Medium (ProgSADMask 10) with no opt
#          mask   that Mask call on its own, vectors from a plain Analyse
#   guard: 1 runs the call through plugin_formats.mvtools_blocks(...,
#          min_cols=MVTOOLS_MASK_MIN_COLS), exactly as the template does for
#          InputType 2/3; 0 (default) calls it as havsfunc does
# The clip is task #69's flow.vpy's: a moving pattern with texture, so the
# vectors are not all zero.
import math
import os
import sys

import vapoursynth as vs
core = vs.core


def arg(name, default):
    v = globals().get(name, default)
    return v.decode() if isinstance(v, bytes) else v


call = arg('call', 'qtgmc')
w, h = map(int, arg('size', '64x96').split('x'))
fmt = arg('fmt', 'YUV420P8')
input_type = int(arg('input_type', '2'))
blksize = int(arg('blksize', '32'))
overlap = int(arg('overlap', '16'))
preset = arg('preset', 'Slow')
guard = arg('guard', '0') == '1'

c = core.std.BlankClip(width=w, height=h, format=getattr(vs, fmt), length=10)
peak = (1 << c.format.bits_per_sample) - 1


def _fill(n, f):
    fo = f.copy()
    for p in range(fo.format.num_planes):
        m = fo[p]
        ph, pw = m.shape
        for y in range(ph):
            for x in range(pw):
                v = (math.sin((x + 3 * n) / 5) + math.cos(y / 7)) * peak / 5 + peak / 2
                m[y, x] = min(peak, int(v + ((x * y + n) % 13) * peak / 64))
    return fo


c = core.std.ModifyFrame(c, c, _fill)
c = core.std.SetFieldBased(c, 0)


def run(clip):
    if call == 'qtgmc':
        import havsfunc as haf
        return haf.QTGMC(clip, Preset=preset, InputType=input_type, BlockSize=blksize,
                         Overlap=overlap, TFF=True)
    if call == 'mask':
        sup = core.mv.Super(clip, pel=2)
        bw = core.mv.Analyse(sup, isb=True, blksize=blksize, overlap=overlap)
        # thscd1 at MVTools' maximum: never a scene change, so the mask is
        # always upsized (task #69's note on flow.vpy).
        return core.mv.Mask(clip, bw, kind=1, ml=10, thscd1=16320)
    raise vs.Error('mask.vpy: unknown call ' + call)


if guard:
    # -a templates=<dir>, else the repo's worker/templates: from the repo root
    # (the repro workflow) or from this script's directory.
    for d in (arg('templates', ''), os.path.join(os.getcwd(), 'worker', 'templates'),
              os.path.join(os.getcwd(), '..', '..', '..', '..', 'worker', 'templates')):
        if d and os.path.exists(os.path.join(d, 'plugin_formats.py')):
            sys.path.insert(0, d)
            break
    import plugin_formats as pf
    out = pf.mvtools_blocks(c, run, min_cols=pf.MVTOOLS_MASK_MIN_COLS, label='mask.vpy')
else:
    out = run(c)
print('mask.vpy: %s %dx%d %s InputType=%d %d/%d %s guard=%s' % (
    call, w, h, fmt, input_type, blksize, overlap, preset, guard), file=sys.stderr)

out = core.std.Trim(out, 2, 6)
out.set_output()
