"""The two comparison grids in the report: rows FlowFPS alone, FlowFPS+NR+Sharpen,
RIFE alone, RIFE+NR+Sharpen; columns real / synthesized / real."""
from harness import *

def grid(src, frames, out):
    rows = []
    for m in ("FLOWFPS", "RIFE"):
        for nr, sh in [(0, 0), (1, 1)]:
            o = run(src, m, nr, sh, 60000, 1001)
            rows.append(core.std.StackHorizontal([o[i] for i in frames]))
    img = core.resize.Bicubic(core.std.StackVertical(rows), format=vs.RGB24, matrix_in_s="170m")
    f = img.get_frame(0)
    pl = [bytes(f[p]) for p in range(3)]
    with open(out, "wb") as fh:
        fh.write(b"P6 %d %d 255\n" % (f.width, f.height))
        fh.write(bytes(v for t in zip(*pl) for v in t))

a = load("small.yuv", 320, 240, vs.YUV420P8, 40, 30000, 1001)
grid(a, (10, 11, 12), "film.ppm")
big = core.resize.Bicubic(a, 640, 480)
pan = core.std.FrameEval(a, lambda n: core.std.CropAbs(big, 320, 240, left=min(n * 8, 318), top=120))
grid(pan, (28, 29, 30), "pan.ppm")
