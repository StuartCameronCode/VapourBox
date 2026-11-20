"""One process, one measure value: a hash per call x depth x picture.
argv: measure (0 | 1 | default). Run it in many fresh processes and count
distinct hashes per key (probe.py): FFTW plans once per process,
so a second process is the only way to see a different plan."""
import os
import sys
# Windows' embeddable Python (._pth) does not put the script's folder on sys.path.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import json
import sys

import vapoursynth as vs
from common import CASES, core, digest, fixture, parse_measure, synthetic

core.num_threads = 8
measure = parse_measure(sys.argv[1])
pics = {
    'syn352': {8: synthetic(bits=8), 16: synthetic(bits=16)},
    'fix720': {8: fixture(720, 480, 12, 8), 16: fixture(720, 480, 12, 16)},
}
out = {}
for pname, by_depth in pics.items():
    for depth, src in by_depth.items():
        for name, fn in CASES.items():
            if name == 'qtgmc' and pname == 'syn352':
                continue  # QTGMC wants an interlaced picture
            out['%s %s %d' % (name, pname, depth)] = digest(fn(src, measure))
print(json.dumps({'measure': sys.argv[1], 'hashes': out}, sort_keys=True))
