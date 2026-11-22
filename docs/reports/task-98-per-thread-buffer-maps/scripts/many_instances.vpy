# INST instances of one plugin call spliced end to end, 8 threads: each
# instance has its own buffer maps, so each instance's first frames are a
# chance for the race. Run in a fresh vspipe each time.
# Env: P (dfttest, dfttest_tb3, lghost, ctmf, tcanny, eedi3), INST, N, NT.
import os
import vapoursynth as vs
core = vs.core
core.num_threads = int(os.environ.get('NT', '8'))
P = os.environ['P']
src = core.std.BlankClip(width=96, height=64, format=vs.YUV420P8,
                         length=int(os.environ.get('N', '20')), color=[100, 120, 140])
calls = {
    'dfttest': lambda c: core.dfttest.DFTTest(c),
    'dfttest_tb3': lambda c: core.dfttest.DFTTest(c, tbsize=3),
    'lghost': lambda c: core.lghost.LGhost(c, mode=[1], shift=[3], intensity=[30]),
    'ctmf': lambda c: core.ctmf.CTMF(c, radius=3),
    'tcanny': lambda c: core.tcanny.TCanny(c),
    'eedi3': lambda c: core.eedi3m.EEDI3(c, field=1),
}
core.std.Splice([calls[P](src) for _ in range(int(os.environ.get('INST', '1000')))]).set_output()
