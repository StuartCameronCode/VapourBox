# Run ONNX models through VSNCNN (ncnn.Model) the way the worker's
# {{#UPSCALE_AI}} block does, on one planar-float frame read from a file, and
# output RGBS (vspipe writes RGB planes in G, B, R order).
#
# vspipe -a deps=<deps/macos-arm64> -a infile=<frame.gbrpf> -a w=W -a h=H
#        -a model=<a.onnx[,b.onnx...]> [-a fp16=0|1] [-a tile=N] [-a streams=N]
#        [-a n=frames] [-a tw=W -a th=H -a down=Spline36] upscale.vpy out.raw
#
# `infile` is ffmpeg's gbrpf32le rawvideo (planes G, B, R). An empty `model`
# runs no network. tw/th resample the result (the Real-ESRGAN General 2x path).
import ctypes
import os
import vapoursynth as vs

core = vs.core
g = globals()
D = os.path.join(g['deps'], 'vapoursynth')
molten = os.path.join(D, 'moltenvk', 'libMoltenVK.dylib')
if os.path.exists(molten):  # macOS: VSNCNN resolves Vulkan from MoltenVK
    ctypes.CDLL(molten, mode=ctypes.RTLD_GLOBAL)
for name in ('libvsncnn.dylib', 'libvsncnn.so', 'vsncnn.dll'):
    path = os.path.join(D, 'ncnn', name)
    if os.path.exists(path):
        core.std.LoadPlugin(path)
        break

w, h = int(g['w']), int(g['h'])
n = int(g.get('n', 1))
with open(g['infile'], 'rb') as fh:
    data = fh.read()
plane = w * h * 4
blank = core.std.BlankClip(width=w, height=h, format=vs.RGBS, length=n, fpsnum=25, fpsden=1)


def fill(n, f):
    f = f.copy()
    for p, src in ((0, 2), (1, 0), (2, 1)):  # R <- file plane 2, G <- 0, B <- 1
        mv = memoryview(f[p]).cast('B')
        stride = f.get_stride(p)
        off = src * plane
        for y in range(h):
            mv[y * stride:y * stride + w * 4] = data[off + y * w * 4: off + (y + 1) * w * 4]
    return f


clip = core.std.ModifyFrame(blank, blank, fill)
fp16 = g.get('fp16', '1') == '1'
tile = int(g.get('tile', '0'))
# clamp=1 (default) keeps a tile within the frame, as the template does;
# clamp=0 passes it as given (a tile larger than the frame segfaults VSNCNN).
clamp = g.get('clamp', '1') == '1'
for m in [m for m in g.get('model', '').split(',') if m]:
    kw = {}
    if tile:
        size = [min(tile, clip.width), min(tile, clip.height)] if clamp else [tile, tile]
        kw = dict(tilesize=size, overlap=[16, 16])
    clip = core.ncnn.Model(clip, network_path=m, fp16=fp16,
                           num_streams=int(g.get('streams', '2')), **kw)
tw, th = int(g.get('tw', clip.width)), int(g.get('th', clip.height))
if (tw, th) != (clip.width, clip.height):
    clip = getattr(core.resize, g.get('down', 'Spline36'))(clip, tw, th)
clip.set_output()
