"""Task #75: Lut2 at 10 bits, function= against a precomputed lut= list, and std.Expr bitand."""
import time, vapoursynth as vs
core = vs.core
c = core.std.BlankClip(format=vs.GRAY10, width=160, height=120, length=4)
c = core.grain.Add(c, var=500)
t=time.time(); a = core.std.Lut2(c, c[1:]+c[0], function=lambda x, y: x & y); print('Lut2 function= 10-bit %.2f s' % (time.time()-t))
t=time.time(); lut = [x & y for y in range(1024) for x in range(1024)]; b = core.std.Lut2(c, c[1:]+c[0], lut=lut); print('Lut2 lut= list 10-bit %.2f s' % (time.time()-t))
print('identical', core.std.PlaneStats(a, b).get_frame(0).props['PlaneStatsDiff'] == 0)
try:
    t=time.time(); e = core.std.Expr([c, c[1:]+c[0]], 'x y bitand'); e.get_frame(0); print('Expr bitand %.3f s identical %s' % (time.time()-t, core.std.PlaneStats(a, e).get_frame(0).props['PlaneStatsDiff'] == 0))
except Exception as ex: print('Expr bitand:', ex)
print(core.core_version.release_major, vs.__version__)
