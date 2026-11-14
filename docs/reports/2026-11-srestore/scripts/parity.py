"""Is worker/templates/srestore.py's detector havsfunc's, line for line?

Drives both linearly (every frame, in order, one thread) on the deinterlaced
fixtures and compares every decision. havsfunc is instrumented on a copy in
the scratch directory; the bundle's file is not touched.
"""
import importlib.util
import json
import os
import sys

import probelib as P
from probelib import core

core.num_threads = 1


def instrumented_havsfunc():
    src = open(os.path.join(P.DEPS, 'python-packages', 'havsfunc.py')).read()
    a = "        ### output clip ###\n"
    b = "    last = core.std.FrameEval(source, eval=srestore_inside, prop_src=[bclpYStats, dclpYStats, dclipYStats])\n"
    assert src.count(a) == 1 and src.count(b) == 1
    src = src.replace(a, "        DEC[n] = (opos + dup - (1 if dup == 0 and mer and dbc < dcn else 0), bool(mer and dup == 0))\n" + a)
    src = src.replace(b, b + "    global LAST; LAST = last\n")
    path = os.path.join(P.SCRATCH, 'havsfunc_instrumented.py')
    open(path, 'w').write("DEC = {}\nLAST = None\n" + src)
    spec = importlib.util.spec_from_file_location('havsfunc_instrumented', path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


haf = instrumented_havsfunc()
result = {}
for fx in ('film', 'pal'):
    clip = P.bobbed(fx)
    num, den = P.TARGETS[fx]
    frfac, numr, denm = P.srestore.ratio(clip.fps_num, clip.fps_den, num, den)
    haf.DEC.clear()
    haf.srestore(clip, frate=num / den)
    for n in range(len(clip)):
        haf.LAST.get_frame(n)
    ref = [tuple(haf.DEC[n]) for n in range(len(clip))]
    port = P.decisions_linear(P.props(clip, fx), frfac, numr, denm)
    same = sum(1 for a, b in zip(ref, port) if a == b)
    result[fx] = {'frames': len(clip), 'identical_decisions': same,
                  'ratio': [numr, denm]}
    print(fx, result[fx])
json.dump(result, open(os.path.join(P.SCRATCH, 'parity.json'), 'w'), indent=1)
