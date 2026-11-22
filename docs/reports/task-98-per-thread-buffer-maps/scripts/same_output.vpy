# One plugin call on a grain-noised 720x480 clip, 30 frames, 8 threads: the
# raw output's hash is compared between the bundle's build and the patched one.
# Env: P (dfttest, lghost, ctmf, tcanny, eedi3).
import os
import vapoursynth as vs
core = vs.core
core.num_threads = 8
P = os.environ['P']
src = core.std.BlankClip(width=720, height=480, format=vs.YUV420P8, length=30, color=[100, 120, 140])
src = core.grain.Add(src, var=60, uvar=20, seed=7, constant=False)
out = {
    'dfttest': lambda c: core.dfttest.DFTTest(c, tbsize=3),
    'lghost': lambda c: core.lghost.LGhost(c, mode=[1, 2], shift=[3, -5], intensity=[30, 20]),
    'ctmf': lambda c: core.ctmf.CTMF(c, radius=3),
    'tcanny': lambda c: core.tcanny.TCanny(c),
    'eedi3': lambda c: core.eedi3m.EEDI3(c, field=1),
}[P](src)
out.set_output()
