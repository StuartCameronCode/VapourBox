# One Stab variant over a raw clip on stdin; see measure.sh.
#   MODE=stab     havsfunc Stab, as the templates called it before task #32
#   MODE=weave    stabilize.weave (motion measured at 16-bit)
#   MODE=shift    DepanEstimate between each frame and a copy shifted by DX/DY
#                 pixels, printing the estimate (no averaging, no compensation)
import os
import sys

import vapoursynth as vs

core = vs.core
sys.path.insert(0, os.environ["TEMPLATES"])
from pipe_source import create_pipe_clip  # noqa: E402

if os.environ.get("THREADS"):
    core.num_threads = int(os.environ["THREADS"])
pf = os.environ["PF"]
clip = create_pipe_clip(352, 288, 25, 25, 1, pf, cache_frames=64)
mode = os.environ["MODE"]

if mode == "stab":
    import havsfunc as haf
    clip = haf.Stab(clip, dxmax=4, dymax=4, mirror=0)
elif mode == "weave":
    from stabilize import weave
    clip = weave(clip, dxmax=4, dymax=4, mirror=0)
elif mode == "shift":
    dx, dy = int(os.environ["DX"]), int(os.environ["DY"])
    a = core.std.Crop(clip, left=4, right=4, top=4, bottom=4)
    b = core.std.Crop(clip, left=4 + dx, right=4 - dx, top=4 + dy, bottom=4 - dy)
    md = core.mv.DepanEstimate(core.std.Interleave([a, b]), trust=0, dxmax=4, dymax=4)

    def _report(n, f):
        if n % 2:
            sys.stderr.write("EST %d %.4f %.4f\n" % (n, f.props["Depan_dx"], f.props["Depan_dy"]))
        return f.copy()

    clip = core.std.ModifyFrame(md, md, _report)
clip.set_output()
