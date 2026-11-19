"""Writes one .vpy per (filter, source): make_vpy.py <templates dir> <out dir>.
Each reads raw frames from stdin through VapourBox's own pipe_source.py, as the
worker's scripts do, so both arms run the same reader."""
import sys, os
tmpl, out = sys.argv[1], sys.argv[2]
SOURCES = {'sd': (720, 576, 500), 'hd': (1920, 1080, 200)}
FILTERS = {
    # transport only: what the pipe itself costs
    'passthrough': 'clip = src',
    # a cheap spatial filter: frame-parallel, little work per frame
    'light': 'clip = core.std.BoxBlur(src, hradius=2, vradius=2)',
    # QTGMC Medium, double rate, TFF: the app's default pass
    'qtgmc': ("clip = core.std.SetFieldBased(src, 2)\n"
              "clip = haf.QTGMC(clip, Preset='Medium', TFF=True)"),
}
for sname, (w, h, n) in SOURCES.items():
    for fname, body in FILTERS.items():
        with open(os.path.join(out, f'{fname}_{sname}.vpy'), 'w') as f:
            f.write(f"""import sys
sys.path.insert(0, r"{tmpl}")
import vapoursynth as vs
core = vs.core
import havsfunc as haf
from pipe_source import create_pipe_clip
src = create_pipe_clip({w}, {h}, {n}, 25, 1, 'yuv420p')
{body}
clip.set_output()
""")
