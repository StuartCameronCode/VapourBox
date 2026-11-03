# One variant of the deblock-order probe. Reads raw 720x576 yuv420p TFF
# interlaced frames from stdin through the app's own pipe_source.py.
#
# Environment:
#   TPL      worker/templates (for pipe_source)
#   NF       frame count
#   ORDER    none | after | woven | field
#              none  - no deblocking
#              after - deblock the deinterlaced output (VapourBox today)
#              woven - deblock the woven interlaced frame, then deinterlace
#              field - SeparateFields -> deblock -> Weave, then deinterlace
#   METHOD   qed | simple | dct  (haf.Deblock_QED / core.deblock.Deblock /
#            core.dctf.DCTFilter with the app's default curve: cutoff 5,
#            strength 0.6, luma only)
#   DEINT    1 = QTGMC Slower double rate (default), 0 = leave interlaced
#   Q1, Q2   quant1 / quant2 (defaults 24 / 26, the app's defaults)
import os, sys
sys.path.insert(0, os.environ['TPL'])
from pipe_source import create_pipe_clip
import vapoursynth as vs
import havsfunc as haf
core = vs.core

order = os.environ.get('ORDER', 'none')
method = os.environ.get('METHOD', 'qed')
deint = os.environ.get('DEINT', '1') == '1'
q1 = int(os.environ.get('Q1', '24'))
q2 = int(os.environ.get('Q2', '26'))


def deblock(c):
    if method == 'qed':
        return haf.Deblock_QED(c, quant1=q1, quant2=q2)
    if method == 'dct':
        return core.dctf.DCTFilter(c, factors=[1, 1, 1, 1, 1, 1, 0.7, 0.4], planes=[0])
    return core.deblock.Deblock(c, quant=q1)


clip = create_pipe_clip(720, 576, int(os.environ['NF']), 25, 1, 'yuv420p')
clip = core.std.SetFieldBased(clip, 2)

if order == 'woven':
    clip = deblock(clip)
elif order == 'field':
    fields = core.std.SeparateFields(clip, tff=True)
    clip = core.std.DoubleWeave(deblock(fields), tff=True)[::2]
    clip = core.std.SetFieldBased(clip, 2)

if deint:
    clip = haf.QTGMC(clip, Preset='Slower', TFF=True)

if order == 'after':
    clip = deblock(clip)

clip.set_output()
