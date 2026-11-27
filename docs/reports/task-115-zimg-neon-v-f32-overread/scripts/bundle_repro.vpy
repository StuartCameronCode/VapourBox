# The two resizes behind task #115's ASan reports, through VapourSynth's own
# resize (task #115):
#   kind=up    YUV420P8 -> RGBS, Bicubic: chroma 2x up vertically, 4 taps
#   kind=down  RGB24 -> YUV420P8, Point: chroma 2x down vertically, 1 tap
# Prints the frames' CRC on stderr.
import sys
import zlib
import vapoursynth as vs

core = vs.core
args = globals()


def arg(name, default):
    v = args.get(name, default)
    return v.decode() if isinstance(v, bytes) else v


kind = arg("kind", "up")
w, h = (int(x) for x in arg("size", "96x64").split("x"))
frames = int(arg("frames", "3"))
threads = int(arg("threads", "0"))
if threads:
    core.num_threads = threads

if kind == "up":
    clip = core.std.BlankClip(width=w, height=h, format=vs.YUV420P8, length=frames, color=[120, 90, 160])
    out = core.resize.Bicubic(clip, format=vs.RGBS, matrix_in_s="709")
else:
    clip = core.std.BlankClip(width=w, height=h, format=vs.RGB24, length=frames, color=[200, 40, 90])
    out = core.resize.Point(clip, format=vs.YUV420P8, matrix_s="709")

crc = 0
for n in range(frames):
    f = out.get_frame(n)
    for p in range(f.format.num_planes):
        crc = zlib.crc32(bytes(f[p]), crc)
print("bundle_repro: %s %dx%d, %d frames, crc %08x" % (kind, w, h, frames, crc), file=sys.stderr)
out.set_output()
