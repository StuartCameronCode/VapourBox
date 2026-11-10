"""Denoisers x sharpeners x FlowFPS/RIFE at 8 and 10 bits: the dark-patch matrix."""
import os, sys
from harness import *
s8 = load("small.yuv", 320, 240, vs.YUV420P8, 40, 30000, 1001)
s10 = core.resize.Point(s8, format=vs.YUV420P10)
NR = {"none": lambda c: c,
      "smdegrain": lambda c: haf.SMDegrain(c, tr=2, thSAD=300),
      "mctd": lambda c: haf.MCTemporalDenoise(c, settings="medium"),
      # KNLMeansCL omitted: needs an OpenCL device (none on the machine measured).
      #"knlm": lambda c: core.knlm.KNLMeansCL(core.knlm.KNLMeansCL(c, d=1, a=2, s=4, h=1.2, channels="Y"), d=1,a=2,s=4,h=1.2,channels="UV"),
      "dfttest": lambda c: core.dfttest.DFTTest(c, sigma=8),
      "fft3d_sharp": lambda c: core.fft3dfilter.FFT3DFilter(c, sigma=2, sharpen=1.0)}
SH = {"none": lambda c: c,
      "lsfmod200": lambda c: haf.LSFmod(c, strength=200),
      "cas1": lambda c: core.cas.CAS(c, sharpness=1.0),
      "awarp": lambda c: core.warp.AWarpSharp2(c, thresh=128, blur=2, type=0, depth=16)}
for which, (sname, src) in [(m, s) for m in ("FLOWFPS", "RIFE") for s in (("8bit", s8), ("10bit", s10))]:
    for nn, nf in NR.items():
        for sn, sf in SH.items():
            if nn != "none" and sn not in ("none","lsfmod200") and nn != "smdegrain": continue
            g = {"clip": sf(nf(src)), "core": core, "vs": vs, "haf": haf}
            try:
                exec(frame_rate_block(which, 60000, 1001), g)
                v = dark_metric(g["clip"])
            except Exception as e:
                print(f"{sname} {which} {nn}+{sn}: ERROR {e}", flush=True); continue
            dm = sum(a for a,_,_ in v)/len(v); dx = max(v); bx = max(b for _,b,_ in v)
            print(f"{sname:5s} {which:7s} {nn:11s}+{sn:9s}: dark mean {100*dm:.3f}% max {100*dx[0]:.3f}% (f{dx[2]}) bright max {100*bx:.3f}%", flush=True)
