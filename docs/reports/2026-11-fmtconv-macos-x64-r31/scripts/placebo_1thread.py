# QTGMC Placebo hashes with VapourSynth on ONE thread. With the default thread
# count Placebo's output changes from run to run of the same build (see the
# report), so only a single-threaded run can say whether fmtconv changes it.
# Same source and hashing as probe.py. Writes JSON to the last argument.
import sys, hashlib, json
import vapoursynth as vs
core = vs.core
core.num_threads = 1
import havsfunc as haf

def src(fmt, w=320, h=240, n=12):
    base = core.std.BlankClip(width=w, height=h, format=vs.YUV444P16, length=n, color=[32768, 32768, 32768])
    c = core.grain.Add(base, var=20000, uvar=20000, seed=3, constant=False)
    c = core.std.BoxBlur(c, hradius=3, vradius=2)
    c = core.grain.Add(c, var=600, uvar=300, seed=7, constant=False)
    return core.resize.Bicubic(c, format=fmt, dither_type="none")

def digest(clip):
    h = hashlib.md5()
    for i in range(clip.num_frames):
        f = clip.get_frame(i)
        for p in range(f.format.num_planes):
            h.update(bytes(memoryview(f[p])))
    return h.hexdigest()[:16]

out = {}
for name, fmt in {"420p8": vs.YUV420P8, "420p10": vs.YUV420P10, "422p10": vs.YUV422P10}.items():
    fb = core.std.SetFieldBased(src(fmt), 2)
    out[f"qtgmc_placebo_1thread/{name}"] = digest(haf.QTGMC(core.std.Trim(fb, 0, 5), Preset='Placebo', TFF=True))
json.dump(out, open(sys.argv[-1], "w"), indent=1, sort_keys=True)
print(out)
