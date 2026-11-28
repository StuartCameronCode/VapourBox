"""Issue #253: frames per second of automatic white balance on its own,
before and after, with the function taken verbatim from the two copies of
pipeline_template.vpy (probe_exact.load). Automatic levels, which this change
leaves as it was, is timed alongside for scale.

Source: a synthetic 706x480 clip (the issue's capture size) with AddGrain
noise, a chroma cast that changes every frame and a luma contrast that drifts,
at 8 and 10 bits 4:2:0. Each variant is pulled through `frames()`
(VapourSynth's own threads, no decoder or encoder) after a 50-frame warm-up.
The numbers are each filter's own cost on this machine, not a job's speed:
chain_timing.py measures that.

Usage: as probe_exact.py: <deps> <old.vpy> <new.vpy> [frames]
"""
import os
import sys
import time

deps, old_path, new_path = sys.argv[1:4]
N = int(sys.argv[4]) if len(sys.argv) > 4 else 1200
sys.path.insert(0, deps)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_exact as pe  # noqa: E402

core, vs = pe.core, pe.vs


def source(bits):
    peak = (1 << bits) - 1
    c = pe.white_source(bits, 2, N)
    return core.akarin.Expr([c], [f'x {peak // 2} - N 400 % 0.002 * 0.6 + * {peak // 2} + X 0.05 * {peak / 255.0} * +',
                                  '', ''])


def fps(clip):
    for _ in clip[:50].frames():
        pass
    t = time.perf_counter()
    for _ in clip.frames():
        pass
    return clip.num_frames / (time.perf_counter() - t)


for bits in (8, 10):
    c = source(bits)
    print(f'{bits}-bit 706x480 4:2:0, {N} frames; no filter: {fps(c):.0f} fps', flush=True)
    for label, path, akarin in (('before (main)', old_path, True),
                                ('after, akarin', new_path, True),
                                ('after, no akarin (macOS x64)', new_path, False)):
        fn = pe.load(path, '_auto_white', akarin)[0]
        print(f'  _auto_white   {label:30s} {fps(fn(c, 1.0)):8.0f} fps', flush=True)
    fn = pe.load(new_path, '_auto_levels', True)[0]
    print(f'  _auto_levels  {"(unchanged)":30s} {fps(fn(c, 16, 235, 1.0)):8.0f} fps', flush=True)
