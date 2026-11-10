"""How far outside [0,1] the RGBS fed to RIFE goes, with and without NR/sharpen."""
import vapoursynth as vs, havsfunc as haf, sys, ctypes
core = vs.core
W,H,N=320,240,40
raw=open("small.yuv",'rb').read()
fs=W*H*3//2
c=core.std.BlankClip(width=W,height=H,format=vs.YUV420P8,length=N,fpsnum=30000,fpsden=1001)
def put(n,f):
    f=f.copy(); o=n*fs
    for p,(w,h) in enumerate([(W,H),(W//2,H//2),(W//2,H//2)]):
        ptr=f.get_write_ptr(p).value; st=f.get_stride(p)
        for y in range(h):
            ctypes.memmove(ptr+y*st, raw[o+y*w:o+(y+1)*w], w)
        o+=w*h
    return f
src=core.std.ModifyFrame(c,c,put)
def stats(name,clip):
    rgb=core.resize.Bicubic(clip,format=vs.RGBS,matrix_in_s="170m",range_in_s="limited")
    mn,mx,neg=9,-9,0.0
    for p in range(3):
        pl=core.std.ShufflePlanes(rgb,p,vs.GRAY)
        s=core.std.PlaneStats(pl); ng=core.std.PlaneStats(core.std.Expr(pl,"x -0.05 < 1 0 ?"))
        for i in range(N):
            fp=s.get_frame(i).props; mn=min(mn,fp.PlaneStatsMin); mx=max(mx,fp.PlaneStatsMax)
            neg=max(neg,ng.get_frame(i).props.PlaneStatsAverage)
    print(f"{name:20s} min={mn:+.3f} max={mx:.3f} worst-frame share < -0.05: {100*neg:.3f}%")
stats("source",src)
stats("smdegrain",haf.SMDegrain(src,tr=2,thSAD=300))
stats("lsfmod",haf.LSFmod(src,strength=100))
stats("smdegrain+lsfmod",haf.LSFmod(haf.SMDegrain(src,tr=2,thSAD=300),strength=100))
