"""Task #75: one cell at a time, per depth and subsampling (graph build + one frame).
Usage: time_cells.py <ffmpeg> <call,call,...> [memo]. Run with the bundle's Python under WorkerHarness.workerEnv (see reproduce.sh)."""
import os
import importlib.util, sys, time, tempfile
spec = importlib.util.spec_from_file_location('probe', os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..', '..', 'Scripts', 'probe-plugin-formats.py'))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
import vapoursynth as vs
core = vs.core
calls = m._calls()
if len(sys.argv) > 3 and sys.argv[3] == 'memo':
    m.memo_havsfunc_luts()
with tempfile.TemporaryDirectory() as tmp:
    fx = m.make_fixtures(tmp, [m.BASE], sys.argv[1])
    path = fx['160x120']
    w, h = m.BASE
    import ctypes
    blank = core.std.BlankClip(width=w, height=h, format=vs.YUV444P16, length=m.FRAMES)
    fsize = w*h*6
    def fill(n, f):
        o = f.copy(); data = open(path,'rb').read()[n*fsize:(n+1)*fsize]; off=0
        for p in range(3):
            b = ctypes.cast(o.get_write_ptr(p), ctypes.c_void_p).value; st=o.get_stride(p)
            for y in range(h):
                ctypes.memmove(b+y*st, data[off:off+w*2], w*2); off += w*2
        return o
    src = core.std.ModifyFrame(blank, blank, fill)
    for key in sys.argv[2].split(','):
        for ss,(sw,sh) in (('420',(1,1)),('422',(1,0)),('444',(0,0))):
            for bits in (8,10,12,16):
                for field in (0,):
                    fmt = core.query_video_format(vs.YUV, vs.INTEGER, bits, sw, sh)
                    c = core.std.SetFieldBased(core.resize.Bicubic(src, format=fmt.id, dither_type='none'), field)
                    t=time.time(); 
                    try:
                        o = calls[key]['run'](c); tb=time.time()-t; o.get_frame(5); ok='ok'
                    except Exception as e: tb=time.time()-t; ok=str(e).splitlines()[0][:60]
                    print('%-32s %sp%-2d f%d build %.2f s total %.2f s %s' % (key, ss, bits, field, tb, time.time()-t, ok), flush=True)
