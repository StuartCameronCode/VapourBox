# The report's images: a 240x180 crop of small_clip.mp4 at 8 s (make_frames.sh),
# as the source, 6bfbdd42 (sigma=[100]) and r4 (sigma=[25, 80, 250, 100],
# what r4 runs for sigma=[100]), and their absolute difference x4, written as
# PGM into $SCRATCH/img. make_images.sh turns them into the PNGs in img/.
import os
import vapoursynth as vs
core = vs.core
S = os.environ['SCRATCH']
X, Y, CW, CH = 240, 300, 240, 180
data = open(os.path.join(S, 'f8.gray'), 'rb').read()
rows = [data[y * 720:(y + 1) * 720] for y in range(540)]
os.makedirs(os.path.join(S, 'img'), exist_ok=True)
import ctypes
base = core.std.BlankClip(width=720, height=540, format=vs.GRAY8, length=1)
def draw(n, f):
    f = f.copy(); ptr, st = f.get_write_ptr(0).value, f.get_stride(0)
    for y, r in enumerate(rows):
        ctypes.memmove(ptr + y * st, r, 720)
    return f
src = core.std.ModifyFrame(base, base, draw)
fixed = core.retinex.MSRCP(src, sigma=[100], lower_thr=0.001, upper_thr=0.001)
r4 = core.retinex.MSRCP(src, sigma=[25, 80, 250, 100], lower_thr=0.001, upper_thr=0.001)
dif = core.std.Expr([fixed, r4], 'x y - abs 4 * 255 min')
for name, c in (('1-source', src), ('2-fixed-6bfbdd42', fixed), ('3-r4', r4), ('4-diff-x4', dif)):
    c = core.std.Crop(c, X, 720 - X - CW, Y, 540 - Y - CH)
    f = c.get_frame(0)
    ptr, st = f.get_read_ptr(0).value, f.get_stride(0)
    with open(os.path.join(S, 'img', name + '.pgm'), 'wb') as o:
        o.write(b'P5 %d %d 255\n' % (CW, CH))
        for y in range(CH):
            o.write(ctypes.string_at(ptr + y * st, CW))
print('wrote', os.path.join(S, 'img'))
