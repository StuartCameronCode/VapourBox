# The same picture through each build: 720x480 10-bit noise (grain.Add, fixed
# seed), a falling factor curve. Pipe to md5 and compare.
import os
import vapoursynth as vs
core = vs.core
ns = os.environ.get('NS', 'dctf')
if ns != 'dctf':
    core.std.LoadPlugin(os.environ['LIB'])
c = core.std.BlankClip(width=720, height=480, format=vs.YUV420P10, length=10, color=[512, 512, 512])
c = core.grain.Add(c, var=200, uvar=50, seed=1, constant=False)
getattr(core, ns).DCTFilter(c, factors=[1, 0.9, 0.7, 0.5, 0.3, 0.2, 0.1, 0.0]).set_output()
