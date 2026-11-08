"""The ported template blocks against vs-jetpack itself.

vs-jetpack 3.0.0 needs Python 3.13; the bundle's is 3.12, so the reference is
vsjetpack 2.2.7, whose three functions are byte-identical to 3.0.0's (checked
with a diff). Install it beside this script's scratch:

  $DEPS/python/bin/python3 -m pip install --target "$SCRATCH/jp" --no-deps \\
      vsjetpack==2.2.7 'jetpytools>=3.1,<4' 'numpy>=2' psutil rich \\
      typing-extensions markdown-it-py mdurl pygments
  SCRATCH=... ./run.sh ports_vs_reference.py

Reports mean |port - reference| in 8-bit levels (luma, chroma) on the fixtures.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
S = os.environ['SCRATCH']
sys.path.append(os.path.join(S, 'jp'))
sys.argv = [sys.argv[0]]
os.environ.setdefault('NFR', '6')
# Reuse ports_compare's loaders and the template-block runner, without running it.
src = open(os.path.join(HERE, 'ports_compare.py')).read()
exec(src[:src.index('# ---- vine_dehalo')])
exec(src[src.index('def gauss('):src.index("out['vine'] = {}")])
exec(src[src.index('def stinx('):src.index("out['mpeg2stinx'] = {}")])
exec(src[src.index('def fades('):src.index('def field_gap(')])

# vs-jetpack's scalers need the resize2 plugin, which the bundle does not ship
# (the ports do not use it), so vine_dehalo's reference cannot run against the
# bundle and is reported as not run. mpeg2stinx and FixInterlacedFades need
# only bundled plugins. resize2 is a superset of the core resizers, so its
# kernels are pointed at core.resize for the reference run (vine_dehalo's
# NNEDI3 supersample and Catrom downscale pass no resize2-only arguments).
import vskernels  # noqa: E402

for _name in dir(vskernels):
    _cls = getattr(vskernels, _name)
    if not isinstance(_cls, type) or 'zimg' not in getattr(_cls, '__module__', ''):
        continue
    for _attr in ('scale_function', 'resample_function'):
        _ref = getattr(getattr(_cls, _attr, None), 'func_ref', None)
        if _ref is not None and hasattr(core.resize, _ref[1]):
            setattr(_cls, _attr, getattr(core.resize, _ref[1]))
# 2.2.7's nl_means predates vszip's CPU NLMeans and finds no backend here;
# 3.0.0's CPU backend is exactly `clip.vszip.NLMeans(*args, **kwargs)`, so
# route it there (wmode/wref/channels/rclip pass straight through).
from vsdenoise import nlm as _nlm  # noqa: E402

_nlm.NLMeans.Backend.NLMeans = lambda self, clip, *a, **k: clip.vszip.NLMeans(*a, **k)
from vsdehalo import vine_dehalo  # noqa: E402
from vsdenoise import mpeg2stinx  # noqa: E402
from vsdeinterlace import FixInterlacedFades  # noqa: E402

res = {}
clean = load(os.path.join(S, 'fx', 'kodim08_pan.mkv'), 'yuv420p', frames=NFR)
halo = core.std.SetFieldBased(expr([clean, gauss(clean, 1.5)], 'x x y - 1.5 * +'), 0)
for bits in (8, 10):
    h = halo if bits == 8 else core.resize.Point(halo, format=halo.format.replace(bits_per_sample=bits).id)
    try:
        port, ref = vine(h), vine_dehalo(h)
        res[f'vine {bits}-bit'] = (mad8(port, ref, 0), mad8(port, ref, 1))
    except (vs.Error, AttributeError) as e:
        print(f'vine {bits}-bit: reference not run ({str(e).splitlines()[0][:90]})')

enc = core.std.SetFieldBased(load(os.path.join(S, 'fx', 'kodim08_mpeg2_1000.mkv'), 'yuv420p', frames=NFR), 0)
for bits in (8, 10):
    e = enc if bits == 8 else core.resize.Point(enc, format=enc.format.replace(bits_per_sample=bits).id)
    port, ref = stinx(e), mpeg2stinx(e)
    res[f'mpeg2stinx {bits}-bit'] = (mad8(port, ref, 0), mad8(port, ref, 1))

c = core.resize.Point(clean, format=vs.YUV420PS)
faded = core.std.SetFieldBased(expr([core.std.SeparateFields(core.std.SetFieldBased(c, 0), tff=True)],
                                    ['x 0.6 *', 'x 0.6 *', 'x 0.6 *']), 0)
# a frame whose fields sit at different fade levels: top 0.8, bottom 0.5
fl = core.std.SeparateFields(core.std.SetFieldBased(c, 0), tff=True)
top = expr([fl[::2]], ['x 0.8 *'] * 3)
bot = expr([fl[1::2]], ['x 0.5 *'] * 3)
mixed = core.std.SetFieldBased(core.std.DoubleWeave(core.std.Interleave([top, bot]), tff=True)[::2], 0)
for mode, ref_fn in (('average', FixInterlacedFades.AVERAGE), ('match', FixInterlacedFades.MATCH)):
    port = fades(mixed, mode)
    ref = ref_fn(mixed)
    res[f'FixInterlacedFades {mode} (float)'] = (mad8(port, ref, 0), mad8(port, ref, 1))

for k, (y, u) in res.items():
    print(f'{k:36s} |port - vs-jetpack|  Y {y:.4f}  U {u:.4f} levels')
