# The 62 equality cases: what VapourBox reaches through fmtconv (havsfunc Bob,
# Resize as QTGMC/santiag call it, bitdepth, mvsfunc Depth, MinBlur, QTGMC) at
# 8/10/14/16-bit, plus the cases r31's chroma-placement fix is documented to
# change (EXPECT_DIFF_*). Writes {case: md5 prefix of every plane of every frame}
# as JSON to the last argument. Run it through run-with-dylib.sh once per dylib
# (twice for one of them, to see which cases are nondeterministic).
import sys, hashlib, json
import vapoursynth as vs
core = vs.core
import havsfunc as haf
import mvsfunc as mvf

def src(fmt, w=320, h=240, n=12):
    # deterministic textured, moving pattern with grain, built at 16-bit then converted
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
def case(k, fn):
    try:
        out[k] = digest(fn())
    except vs.Error as e:
        out[k] = "ERROR: " + str(e).strip().splitlines()[-1]
fmts = {"420p8": vs.YUV420P8, "420p10": vs.YUV420P10, "422p10": vs.YUV422P10, "420p14": vs.YUV420P14, "444p16": vs.YUV444P16, "420p16": vs.YUV420P16}
for name, fmt in fmts.items():
    c = src(fmt)
    fb = core.std.SetFieldBased(c, 2)
    case(f"bob/{name}", lambda: haf.Bob(fb, tff=True))
    case(f"sbb_gauss/{name}", lambda: haf.Resize(c, c.width, c.height, sw=c.width + 0.0001, sh=c.height + 0.0001, kernel='gauss', a1=2, dmode=1))
    cs = [0.5, 0.5 * (1 << c.format.subsampling_h)]
    case(f"santiag_shift/{name}", lambda: haf.Resize(c, c.width, c.height, sy=cs, dmode=1))
    case(f"resize_down/{name}", lambda: haf.Resize(c, 200, 150, dmode=1))
    case(f"mvf_depth8/{name}", lambda: mvf.Depth(c, 8))
    case(f"bitdepth16_full/{name}", lambda: core.fmtc.bitdepth(c, bits=16, fulls=False, fulld=True))
    case(f"minblur/{name}", lambda: haf.MinBlur(c, r=3))
    case(f"qtgmc_placebo/{name}", lambda: haf.QTGMC(core.std.Trim(fb, 0, 5), Preset='Placebo', TFF=True))
    case(f"qtgmc_draft/{name}", lambda: haf.QTGMC(core.std.Trim(fb, 0, 5), Preset='Draft', TFF=True))
    # Cases r31's chroma-placement fix is documented to change:
    case(f"EXPECT_DIFF_dv_itl/{name}", lambda: core.fmtc.resample(core.std.SeparateFields(c, tff=True), scalev=2, interlaced=1, interlacedd=0, cplace="dv"))
c440 = src(vs.YUV440P8)
case("EXPECT_DIFF_mpeg2_440/440p8", lambda: core.fmtc.resample(c440, 320, 480, cplace="mpeg2"))
c410 = src(vs.YUV410P8)
case("EXPECT_DIFF_dv_410/410p8", lambda: core.fmtc.resample(c410, 640, 480, cplace="dv"))
json.dump(out, open(sys.argv[-1], "w"), indent=1, sort_keys=True)
print(len(out), "cases")
