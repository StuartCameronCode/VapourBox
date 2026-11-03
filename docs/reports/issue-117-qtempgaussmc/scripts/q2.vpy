import os, sys, time
sys.path.insert(0, os.environ['TPL'])
from pipe_source import create_pipe_clip
import vapoursynth as vs
core = vs.core
import glob
for f in glob.glob(os.environ.get('PLUG','/nonexist')+'/vapoursynth/plugins/**/*.dylib', recursive=True):
    core.std.LoadPlugin(f)
clip = create_pipe_clip(int(os.environ['W']), int(os.environ['H']), int(os.environ['NF']), 25, 1, 'yuv422p')
clip = core.std.SetFieldBased(clip, 2)
if os.environ.get('DEPTH'):
    clip = core.resize.Point(clip, format=vs.YUV422P10)
which = os.environ.get('WHICH', 'jet')
if which == 'hav':
    import havsfunc
    kw = eval(os.environ.get('KW','{}'))
    out = havsfunc.QTGMC(clip, Preset=os.environ.get('PRESET','Slower'), TFF=True, **kw)
elif which == 'jetconv':
    sys.path.insert(0, os.environ['CONV'])
    from qtgmc_convert import qtgmc_convert
    from vsdeinterlace import QTempGaussMC
    out = QTempGaussMC(**qtgmc_convert(Preset=os.environ.get('PRESET','Slower'))).deinterlace(clip, tff=True)
else:
    from vsdeinterlace import QTempGaussMC
    if os.environ.get('NNPATCH'):
        import vsaa.deinterlacers as d
        d.NNEDI3._deinterlacer_function = property(lambda self: core.nnedi3.nnedi3)
    kw = eval(os.environ.get('KW','{}'))
    out = QTempGaussMC(**kw).deinterlace(clip, tff=True)
if os.environ.get('DEPTH'):
    out = core.resize.Point(out, format=vs.YUV422P8, dither_type='none')
out.set_output()
