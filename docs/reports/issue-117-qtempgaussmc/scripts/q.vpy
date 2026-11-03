import os, sys, time
sys.path.insert(0, os.environ['TPL'])
from pipe_source import create_pipe_clip
import vapoursynth as vs
core = vs.core
import glob
for f in glob.glob(os.environ.get('PLUG','/nonexist')+'/vapoursynth/plugins/**/*.dylib', recursive=True):
    core.std.LoadPlugin(f)
clip = create_pipe_clip(720, 576, 79, 25, 1, 'yuv422p')
clip = core.std.SetFieldBased(clip, 2)
which = os.environ.get('WHICH', 'jet')
if which == 'hav':
    import havsfunc
    out = havsfunc.QTGMC(clip, Preset=os.environ.get('PRESET','Slower'), TFF=True)
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
out.set_output()
