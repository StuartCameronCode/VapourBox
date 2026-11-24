# One VapourSynth resize call, as the failing jobs made it (task #109).
#   vspipe -a src=GRAY16 -a dst=GRAY8 -a size=96x64 -a dither=error_diffusion \
#          -a frames=50 repro.vpy -
# Prints the frames' checksum on stderr. With zimg e2e43d09 (graphengine
# 91c6af4c) an error-diffusion conversion writes past the temporary buffer
# VapourSynth allocates in vszimg::real_get_frame.
import zlib
import sys
import vapoursynth as vs

core = vs.core
args = globals()


def arg(name, default):
    v = args.get(name, default)
    return v.decode() if isinstance(v, bytes) else v


src_name, dst_name = arg("src", "GRAY16"), arg("dst", "GRAY8")
src_fmt, dst_fmt = getattr(vs, src_name), getattr(vs, dst_name)
w, h = (int(x) for x in arg("size", "96x64").split("x"))
dither = arg("dither", "error_diffusion")
frames = int(arg("frames", "50"))
threads = int(arg("threads", "0"))
if threads:
    core.num_threads = threads

# Content does not matter: the filter writes its context at the start of
# every frame, before it reads a sample.
clip = core.std.BlankClip(width=w, height=h, format=src_fmt, length=frames)
kw = {"matrix_in_s": "709", "matrix_s": "709"} if core.get_video_format(dst_fmt).color_family == vs.YUV else {}
out = core.resize.Point(clip, format=dst_fmt, dither_type=dither, range_s="limited", **kw)

crc = 0
for n in range(frames):
    f = out.get_frame(n)
    for p in range(f.format.num_planes):
        crc = zlib.crc32(bytes(f[p]), crc)
print("repro: %s -> %s %dx%d %s, %d frames, crc %08x" % (src_name, dst_name, w, h, dither, frames, crc),
      file=sys.stderr)
out.set_output()
