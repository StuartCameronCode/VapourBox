# One MVTools Flow call on a synthetic clip, for valgrind (task #69).
# vspipe -a call=<name> -a size=WxH -a fmt=<vs format name> \
#        [-a blksize=16] [-a overlap=8] [-a opt=1|0|guard] [-a templates=dir] flow.vpy -
#   call: flowinter | flowfps | mask | qtgmc_inputtype2
#   opt:  1 (MVTools' default: the AVX2 upsizer on an AVX2 CPU), 0 (the C
#         upsizer), guard (plugin_formats.mvtools_flow_opt, what the template
#         passes)
# The clip is task #66's bare.vpy's: a moving pattern with texture, so the
# vectors are not all zero.
import math
import os
import sys

import vapoursynth as vs
core = vs.core


def arg(name, default):
    v = globals().get(name, default)
    return v.decode() if isinstance(v, bytes) else v


call = arg('call', 'flowinter')
w, h = map(int, arg('size', '64x48').split('x'))
fmt = arg('fmt', 'YUV420P8')
blksize = int(arg('blksize', '16'))
overlap = int(arg('overlap', '8'))
opt_arg = arg('opt', '1')

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

if opt_arg == 'guard':
    # The repo's worker/templates, four directories up from this script.
    # -a templates=<dir>, else the repo's worker/templates: vsscript runs a
    # script in its own directory, docs/reports/<slug>/scripts.
    sys.path.insert(0, arg('templates', os.path.join(os.getcwd(), '..', '..', '..', '..', 'worker', 'templates')))
    import plugin_formats as pf
    opt = pf.mvtools_flow_opt(w, blksize, overlap)
else:
    opt = opt_arg == '1'
print('flow.vpy: %s %dx%d %s %d/%d opt=%s' % (call, w, h, fmt, blksize, overlap, opt), file=sys.stderr)

if call == 'qtgmc_inputtype2':
    # havsfunc's QTGMC runs mv.Mask(kind=1) on InputType 2/3 with ProgSADMask
    # > 0 (the default from Slow): the 8-bit upsizer, with havsfunc's own opt.
    import havsfunc as haf
    out = haf.QTGMC(c, Preset='Slow', InputType=2, BlockSize=blksize, Overlap=overlap, TFF=True)
else:
    sup = core.mv.Super(c, pel=2)
    bw = core.mv.Analyse(sup, isb=True, blksize=blksize, overlap=overlap)
    fw = core.mv.Analyse(sup, isb=False, blksize=blksize, overlap=overlap)
    if call == 'flowinter':
        out = core.mv.FlowInter(c, sup, bw, fw, time=50.0, opt=opt)
    elif call == 'flowfps':
        out = core.mv.FlowFPS(c, sup, bw, fw, num=60000, den=1001, opt=opt)
    elif call == 'mask':
        out = core.mv.Mask(c, bw, kind=1, ml=10, opt=opt)
    else:
        raise vs.Error('flow.vpy: unknown call ' + call)

out = core.std.Trim(out, 2, 6)
out.set_output()
