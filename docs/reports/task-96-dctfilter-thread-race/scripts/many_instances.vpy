# 1000 DCTFilter instances spliced end to end in one graph, 8 threads: each
# instance has its own buffer map, so each one's first frames are a chance for
# the race. Far more sensitive per second than fresh processes. The heavy test
# in app/test/vapoursynth_integration_test.dart runs this shape.
import os
import vapoursynth as vs
core = vs.core
core.num_threads = 8
ns = os.environ.get('NS', 'dctf')
if ns != 'dctf':
    core.std.LoadPlugin(os.environ['LIB'])
src = core.std.BlankClip(width=96, height=64, format=vs.YUV422P12, length=20, color=[2048, 1500, 2500])
src = core.std.SeparateFields(core.std.SetFieldBased(src, 2), tff=True)
f = getattr(core, ns).DCTFilter
core.std.Splice([f(src, factors=[1, 1, 0, 0, 0, 0, 0, 0])
                 for _ in range(int(os.environ.get('INST', '1000')))]).set_output()
