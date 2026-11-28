"""Issue #253: how often does the new automatic white balance (one akarin
expression reading the PlaneStats means as frame properties) differ from the
old one (a std.Expr / akarin expression per frame with the offset written in
as a 6-decimal literal), and by how much?

akarin reads a frame property as a 32-bit float, so the mean (a double in
[0, 1]) loses precision: times a 16-bit peak, about 0.004 of a sample step.
Where the offset's fraction is that close to .5, the sum rounds the other way
and the whole plane of that frame is one sample step off. At 8-12 bits the
lost precision is under 0.0003 of a step.

Per depth, subsampling and strength: frames whose output differs anywhere,
and the largest difference. Same clips as probe_exact.py, longer.

Usage: as probe_exact.py: <deps> <old.vpy> <new.vpy> [frames]
"""
import sys

deps, old_path, new_path = sys.argv[1:4]
N = int(sys.argv[4]) if len(sys.argv) > 4 else 600
sys.path.insert(0, deps)
sys.argv = sys.argv[:4]
import os  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_exact as pe  # noqa: E402

for bits in (8, 10, 12, 16):
    for sub, name in ((2, '4:2:0'), (1, '4:2:2'), (0, '4:4:4')):
        c = pe.white_source(bits, sub, N)
        for strength in (0.37, 0.8, 1.0):
            old = pe.load(old_path, '_auto_white', akarin=True)[0]
            new = pe.load(new_path, '_auto_white', akarin=True)[0]
            d = pe.core.std.Expr([old(c, strength), new(c, strength)], 'x y - abs')
            frames, worst = 0, 0
            for p in (1, 2):
                for f in pe.core.std.PlaneStats(d, plane=p).frames():
                    m = f.props['PlaneStatsMax']
                    worst = max(worst, m)
                    frames += m > 0
            print(f'{bits:2d}-bit {name} strength={strength}: {frames} of {2 * N} '
                  f'chroma planes differ, max {worst}', flush=True)
