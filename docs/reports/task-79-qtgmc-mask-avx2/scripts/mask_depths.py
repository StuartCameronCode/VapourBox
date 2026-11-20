# QTGMC with InputType 2/3 at each depth and preset (task #79, filed as #89):
# MVTools' Mask refuses anything above 8 bits, and havsfunc calls it on the
# clip's own depth at Placebo..Medium (ProgSADMask 10).
# Run with the bundle's Python, havsfunc importable:
#   PYTHONHOME=<deps>/python PYTHONPATH=<deps>/python-packages:<deps> \
#   <deps>/python/bin/python3 mask_depths.py   (macOS: also DYLD_LIBRARY_PATH=<deps>/lib)
import vapoursynth as vs
core = vs.core
import havsfunc as haf

for fmt in ['YUV420P8', 'YUV420P10', 'YUV422P10', 'YUV420P16']:
    for it in [2, 3]:
        for preset in ['Slow', 'Medium', 'Fast']:
            c = core.std.BlankClip(width=128, height=96, format=getattr(vs, fmt), length=10)
            try:
                haf.QTGMC(c, Preset=preset, InputType=it, TFF=True).get_frame(3)
                r = 'ok'
            except vs.Error as e:
                r = 'ERR ' + str(e).splitlines()[0][:90]
            print(fmt, it, preset, r)
