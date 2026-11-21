import sys, vapoursynth as vs
from vsutil_np import plane_rows, md5
core = vs.core
bits = int(sys.argv[1]); H = int(sys.argv[2]); field = int(sys.argv[3])
fmt = core.query_video_format(vs.YUV, vs.INTEGER, bits, 1, 1)
peak = (1 << bits) - 1
base = core.std.BlankClip(width=96, height=H, format=fmt.id, length=5)
base = core.akarin.Expr(base, f"X 7 * Y 13 * + N 5 * + 37 % {peak} * 36 /")
c = core.std.SetFieldBased(base, 2)
out = core.bwdif.Bwdif(c, field=field)
f = out.get_frame(2)
for p in (1,):
    a = plane_rows(f, p)
    print(bits, H, field, 'plane', p, 'rows', len(a), 'last', a[-1][:6], 'prev', a[-2][:6], md5(a))
