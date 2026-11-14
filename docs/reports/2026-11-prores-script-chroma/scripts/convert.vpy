# The worker's script, reduced to the two steps this report is about: read raw
# frames off stdin exactly as the worker does (templates/pipe_source.py), mark
# the clip interlaced when it is still interlaced ({{#SET_FIELD_BASED}}), and
# optionally run the CHROMA_CONVERT block verbatim.
#
# Environment:
#   TEMPLATES  worker/templates (for pipe_source)
#   W H N      frame size and count
#   PIXFMT     the raw frames' ffmpeg pix_fmt (a pipe_source format)
#   FB         _FieldBased to set (2 = TFF, 1 = BFF); unset = progressive
#   CONVERT    a vs format name (YUV422P10, YUV444P10, YUV420P8, ...); unset =
#              leave the format alone, i.e. the old ProRes path
import os
import sys

import vapoursynth as vs

sys.path.insert(0, os.environ["TEMPLATES"])
from pipe_source import create_pipe_clip  # noqa: E402

core = vs.core
clip = create_pipe_clip(int(os.environ["W"]), int(os.environ["H"]),
                        int(os.environ["N"]), 25, 1, os.environ["PIXFMT"])
if os.environ.get("FB"):
    clip = core.std.SetFieldBased(clip, int(os.environ["FB"]))

if os.environ.get("CONVERT"):
    # CHROMA_CONVERT, as in both templates.
    target_format = getattr(vs, os.environ["CONVERT"])
    if clip.format.id != target_format:
        clip = core.resize.Bicubic(clip, format=target_format,
                                   dither_type="error_diffusion")

clip.set_output()
