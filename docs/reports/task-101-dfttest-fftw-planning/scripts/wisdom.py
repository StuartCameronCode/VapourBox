"""Does any DFTTest FFT share an FFTW problem with an FFT3DFilter one? FFTW
reuses wisdom from a more patient planner for a less patient request of the
same problem (task #80), so a DFTTest PATIENT plan of an FFT3DFilter problem
would undo FFT3DFilter's ESTIMATE fix in a graph that has both.

argv: mode, one of
  dfttest  plan (render) every DFTTest call, print the wisdom's problems;
  fft3d    the same for FFT3DFilter's calls (measure=0);
  mixed    every DFTTest call first, then FFT3DFilter's: prints FFT3DFilter's
           hashes, to compare with a fresh `fft3d` process's.
Each at 720x480 and at 96x64 (where FFT3DFilter's frame is one block or
two), 8 and 16 bits. The wisdom is read from the bundle's own libfftw3f
(fftwf_export_wisdom_to_string), the image the plugins load. A problem is
FFTW's md5 of it (the last four words of a wisdom entry)."""
import os
import sys
# Windows' embeddable Python (._pth) does not put the script's folder on sys.path.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ctypes
import json
import re

from common import CASES, INFO_CASES, core, digest, fftw_library, fixture, grain

core.num_threads = 8
mode = sys.argv[1]
FFT3D = {k: v for k, v in INFO_CASES.items() if k.startswith('fft3d')}
pics = {'720': {8: fixture(720, 480, 6, 8), 16: fixture(720, 480, 6, 16)},
        '96': {8: grain(96, 64, 6, 8), 16: grain(96, 64, 6, 16)}}


def render(cases):
    out = {}
    for pname, by_depth in pics.items():
        for depth, src in by_depth.items():
            for name, fn in cases.items():
                if name == 'qtgmc_dfttest' and pname == '96':
                    continue
                try:
                    out['%s %s %d' % (name, pname, depth)] = digest(fn(src))
                except vs_error as e:  # a size a call refuses (96x64 vs a 32-px block)
                    out['%s %s %d' % (name, pname, depth)] = 'error: %s' % e
    return out


import vapoursynth as vs
vs_error = vs.Error


def problems():
    lib = fftw_library()
    lib.fftwf_export_wisdom_to_string.restype = ctypes.c_void_p
    p = lib.fftwf_export_wisdom_to_string()
    text = ctypes.string_at(p).decode()
    # Not freed: fftwf_free from Python crashed Windows' heap (0xC0000374),
    # and the process ends here anyway.
    entries = re.findall(r'\(([^()]+)\)', text)
    out = {}
    for e in entries:
        w = e.split()
        if len(w) < 6 or not w[0].startswith(('fftwf_', 'fftw_')) and not w[-1].startswith('#x'):
            continue
        sig = ' '.join(w[-4:])
        out.setdefault(sig, []).append(w[0])
    return out, len(entries)


if mode == 'dfttest':
    h = render(CASES)
    pr, n = problems()
    print(json.dumps({'mode': mode, 'hashes': h, 'entries': n, 'problems': pr}, sort_keys=True))
elif mode == 'fft3d':
    h = render(FFT3D)
    pr, n = problems()
    print(json.dumps({'mode': mode, 'hashes': h, 'entries': n, 'problems': pr}, sort_keys=True))
elif mode == 'mixed':
    render(CASES)
    h = render(FFT3D)
    print(json.dumps({'mode': mode, 'hashes': h}, sort_keys=True))
