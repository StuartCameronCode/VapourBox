"""Does an ESTIMATE plan inherit a MEASURE plan made earlier in the same
process? FFTW reuses wisdom from a more patient planner for a less patient
request. Plans every call at measure=1 first, then prints the measure=0
hashes, in xproc.py's format: compare them with a fresh `xproc.py 0`.
argv: none."""
import json

from common import CASES, core, digest, fixture, synthetic

core.num_threads = 8
pics = {
    'syn352': {8: synthetic(bits=8), 16: synthetic(bits=16)},
    'fix720': {8: fixture(720, 480, 12, 8), 16: fixture(720, 480, 12, 16)},
}
for measure in (1, 0):
    out = {}
    for pname, by_depth in pics.items():
        for depth, src in by_depth.items():
            for name, fn in CASES.items():
                if name == 'qtgmc' and pname == 'syn352':
                    continue
                out['%s %s %d' % (name, pname, depth)] = digest(fn(src, measure))
print(json.dumps({'measure': '0 after 1', 'hashes': out}, sort_keys=True))
