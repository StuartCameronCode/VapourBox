"""Shared by the issue #148 probes: load raw video, exec the template's FRAME_RATE block, measure."""
import vapoursynth as vs, havsfunc as haf, sys, ctypes, re, os
core = vs.core
DEPS = os.environ["DEPS"]; TEMPLATE = os.environ["TEMPLATE"]

def load(path, W, H, fmt, N, fpsnum, fpsden):
    raw = open(path, 'rb').read()
    c = core.std.BlankClip(width=W, height=H, format=fmt, length=N, fpsnum=fpsnum, fpsden=fpsden)
    f0 = c.get_frame(0); bps = c.format.bytes_per_sample
    geo = [(f0[p].shape[1] * bps, f0[p].shape[0]) for p in range(3)]
    fs = sum(w * h for w, h in geo)
    def put(n, f):
        f = f.copy(); o = n * fs
        for p, (w, h) in enumerate(geo):
            ptr = f.get_write_ptr(p).value; st = f.get_stride(p)
            for y in range(h):
                ctypes.memmove(ptr + y * st, raw[o + y * w:o + (y + 1) * w], w)
            o += w * h
        return f
    return core.std.ModifyFrame(c, c, put)

def section(text, name):
    m = re.search(r"\{\{#%s\}\}\n(.*?)\{\{/%s\}\}" % (name, name), text, re.S)
    return m.group(1)

def frame_rate_block(method, num, den, override=None):
    t = override or open(TEMPLATE).read()
    blk = section(t, "FRAME_RATE")
    for m in ("FLOWFPS", "DUPLICATE", "RIFE"):
        tag = "FRAME_RATE_" + m
        keep = (m == method)
        blk = re.sub(r"\{\{#%s\}\}\n(.*?)\{\{/%s\}\}\n" % (tag, tag),
                     (lambda mm: mm.group(1)) if keep else "", blk, flags=re.S)
    subs = {"FPS_TARGET_NUM": num, "FPS_TARGET_DEN": den, "FPS_BLOCK_SIZE": 16, "FPS_OVERLAP": 8,
            "RIFE_PRELOAD": repr(DEPS + "/vapoursynth/moltenvk/libMoltenVK.dylib"),
            "RIFE_PLUGIN": repr(DEPS + "/vapoursynth/rife/librife.dylib"),
            "RIFE_MODEL_DIR": repr(DEPS + "/vapoursynth/rife/models/rife-v4.26_ensembleFalse"),
            "RIFE_MATRIX": "470bg", "RIFE_RANGE": "limited"}
    for k, v in subs.items():
        blk = blk.replace("{{%s}}" % k, str(v))
    assert "{{" not in blk, blk
    return blk

def run(clip, method, nr, sh, num, den, override=None):
    if nr: clip = haf.SMDegrain(clip, tr=2, thSAD=300)
    if sh: clip = haf.LSFmod(clip, strength=100, overshoot=1, undershoot=1, soft=0)
    g = {"clip": clip, "core": core, "vs": vs, "haf": haf}
    exec(frame_rate_block(method, num, den, override), g)
    return g["clip"]

def luma8(c):
    return core.resize.Point(core.std.ShufflePlanes(c, 0, vs.GRAY), format=vs.GRAY8)

def dark_metric(out, t=24):
    """Share of pixels in each synthesized frame darker than both real neighbours by > t."""
    y = luma8(out)
    prev = y[0] + y[:-1]; nxt = y[1:] + y[-1]
    dark = core.std.Expr([prev, y, nxt], f"y x z min {t} - < 255 0 ?")
    brt = core.std.Expr([prev, y, nxt], f"y x z max {t} + > 255 0 ?")
    ds = core.std.PlaneStats(dark); bs = core.std.PlaneStats(brt)
    vals = [(ds.get_frame(m).props.PlaneStatsAverage, bs.get_frame(m).props.PlaneStatsAverage, m)
            for m in range(1, len(y) - 1, 2)]
    return vals
