"""Issue #253, the first measurement (planning stage, before any change):
the old and the proposed automatic white balance written out inline (not
read from the template), on a synthetic 706x480 clip. Modes: none, old
(akarin node per frame, as the template did), oldstd (std.Expr node per
frame: what macOS x64 runs), new (one akarin expression reading the
PlaneStats means). A sixth argument compares old with new.

Usage: <bundle python> -I bench_first_look.py <deps> <mode> <bits> <frames> [cmp]
Run on deps 1.16.0 (macOS arm64), Apple M1; the machine's load was not recorded.
"""
import sys, time, functools
sys.path.insert(0, sys.argv[1])
import vapoursynth as vs
core = vs.core
mode = sys.argv[2]; bits=int(sys.argv[3]); N=int(sys.argv[4])
fmt = {8: vs.YUV420P8, 10: vs.YUV420P10}[bits]
c = core.std.BlankClip(width=706, height=480, format=fmt, length=N)
c = core.grain.Add(c, var=40, uvar=20, seed=1) if hasattr(core,'grain') else core.noise.Add(c) if hasattr(core,'noise') else c
# vary chroma per frame
c = core.std.Expr([c], ['', 'x N 7 % +', 'x N 5 % -']) if False else c
c = core.akarin.Expr([c], ['', 'x N 13 % 1.37 * + X 0.01 * +', 'x N 11 % 0.91 * - Y 0.02 * +'])
peak=(1<<bits)-1; neutral=1<<(bits-1); s=0.8
su = core.std.PlaneStats(c, plane=1); sv = core.std.PlaneStats(c, plane=2)
if mode=='old':
    def _apply(n,f,ci):
        du=(neutral-f[0].props['PlaneStatsAverage']*peak)*s
        dv=(neutral-f[1].props['PlaneStatsAverage']*peak)*s
        return core.akarin.Expr(ci, ['', 'x {:.6f} +'.format(du), 'x {:.6f} +'.format(dv)])
    out = core.std.FrameEval(c, functools.partial(_apply, ci=c), prop_src=[su,sv])
elif mode=='oldstd':
    def _apply(n,f,ci):
        du=(neutral-f[0].props['PlaneStatsAverage']*peak)*s
        dv=(neutral-f[1].props['PlaneStatsAverage']*peak)*s
        return core.std.Expr(ci, ['', 'x {:.6f} +'.format(du), 'x {:.6f} +'.format(dv)])
    out = core.std.FrameEval(c, functools.partial(_apply, ci=c), prop_src=[su,sv])
elif mode=='new':
    st = core.std.PlaneStats(core.std.PlaneStats(c, plane=1, prop='WbU'), plane=2, prop='WbV')
    out = core.akarin.Expr([st], ['', f'x {neutral} x.WbUAverage {peak} * - {s} * +', f'x {neutral} x.WbVAverage {peak} * - {s} * +'])
elif mode=='none':
    out = c
if len(sys.argv)>5:
    # compare old vs new
    def _apply(n,f,ci):
        du=(neutral-f[0].props['PlaneStatsAverage']*peak)*s
        dv=(neutral-f[1].props['PlaneStatsAverage']*peak)*s
        return core.akarin.Expr(ci, ['', 'x {:.6f} +'.format(du), 'x {:.6f} +'.format(dv)])
    old = core.std.FrameEval(c, functools.partial(_apply, ci=c), prop_src=[su,sv])
    d = core.std.Expr([old,out],'x y - abs')
    mx=0
    for p in range(3):
        dd=core.std.PlaneStats(d,plane=p)
        for f in dd.frames(): mx=max(mx,f.props['PlaneStatsMax'])
    print('maxdiff',mx); sys.exit()
t=time.time()
for f in out.frames(): pass
print(mode,bits,'fps %.1f'%(N/(time.time()-t)))
