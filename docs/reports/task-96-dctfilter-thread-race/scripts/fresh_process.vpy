# One DCTFilter at the failing sweep row's per-field size (96x64 4:2:2 12-bit,
# TFF, split into 96x32 fields), 8 threads. Run in a fresh vspipe each time:
# the race is on each thread's first frame of an instance.
# Env: NS (dctf = the bundle's; else a plugin loaded from LIB), LIB, W, H, N.
import os
import vapoursynth as vs
core = vs.core
core.num_threads = int(os.environ.get('NT', '8'))
ns = os.environ.get('NS', 'dctf')
if ns != 'dctf':
    core.std.LoadPlugin(os.environ['LIB'])
c = core.std.BlankClip(width=int(os.environ.get('W', '96')), height=int(os.environ.get('H', '64')),
                       format=vs.YUV422P12, length=int(os.environ.get('N', '40')),
                       color=[2048, 1500, 2500])
c = core.std.SeparateFields(core.std.SetFieldBased(c, 2), tff=True)
getattr(core, ns).DCTFilter(c, factors=[1, 1, 0, 0, 0, 0, 0, 0]).set_output()
