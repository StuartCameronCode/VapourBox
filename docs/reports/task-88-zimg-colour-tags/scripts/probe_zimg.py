"""Task #88: what zimg (VapourSynth R78's resize) needs to convert between
RGB and the matrices bt2020c / chroma-derived-* / ictcp, and how the readings
compare. Every number in the report comes from this script (run.sh).

Sections:
  1. acceptance: matrix x transfer x primaries, both directions, with the
     transfer/primaries given on the output side only, then on both sides;
  2. exact vs stand-in: round trip, difference in 8-bit RGB, grey;
  3. the CL grey: zimg's Y' for grey vs BT.2020's;
  4. references: chromancl and ICtCp (PQ, HLG) against the standards'
     closed forms;
  5. primaries names VapourSynth accepts for chromancl.
"""
import math
import random

import vapoursynth as vs

core = vs.core

MATS = ["709", "170m", "2020ncl", "ycgco", "2020cl", "chromancl", "chromacl", "ictcp"]
TRCS = [None, "709", "601", "470bg", "2020_10", "st2084", "std-b67", "srgb", "linear"]
PRIS = [None, "709", "170m", "470bg", "2020", "st432-1"]


def runs(f):
    try:
        f().get_frame(0)
        return True
    except vs.Error:
        return False


def swatch(col, w=4, h=4):
    return core.std.BlankClip(width=w, height=h, format=vs.RGB24, color=col, length=1)


def kw(m, t, p, direction, both=True):
    d = {("matrix_in_s" if direction == "in" else "matrix_s"): m}
    if t:
        d["transfer_s" if direction == "out" else "transfer_in_s"] = t
        if both:
            d["transfer_in_s"] = d["transfer_s"] = t
    if p:
        d["primaries_s" if direction == "out" else "primaries_in_s"] = p
        if both:
            d["primaries_in_s"] = d["primaries_s"] = p
    return d


def section1():
    print("== 1. acceptance (rgb->yuv / yuv->rgb), 10-bit limited 4:4:4")
    yuv = core.std.BlankClip(width=8, height=8, format=vs.YUV444P10, color=[500, 400, 600], length=1)
    for both in (False, True):
        print(f"-- transfer/primaries on {'both sides' if both else 'the converted side only'}")
        for m in MATS:
            ok = []
            for t in TRCS:
                for p in PRIS:
                    a = runs(lambda: core.resize.Point(swatch([200, 40, 90]), format=vs.YUV444P10,
                                                       range_s="limited", **kw(m, t, p, "out", both)))
                    b = runs(lambda: core.resize.Point(yuv, format=vs.RGBS, range_in_s="limited",
                                                       **kw(m, t, p, "in", both)))
                    if a and b:
                        ok.append(f"{t}/{p}")
            print(f"{m:10} converts both ways with {len(ok)}/{len(TRCS) * len(PRIS)} transfer/primaries: "
                  + (", ".join(ok) if len(ok) < 20 else "(all but " + str(len(TRCS) * len(PRIS) - len(ok)) + ")"))


W = H = 64


def rgb_content():
    c = core.std.BlankClip(width=W, height=H, format=vs.RGB24, length=1)

    def fill(n, f):
        # Seeded per call: a frame regenerated on a second request must be the
        # same picture (see the report's correction note).
        rnd = random.Random(7)
        fo = f.copy()
        for pl in range(3):
            a = fo[pl]
            for y in range(H):
                for x in range(W):
                    a[y, x] = rnd.randint(0, 255)
        return fo

    return core.std.ModifyFrame(c, c, fill)


def max_diff(a, b, scale=1.0):
    fa, fb = a.get_frame(0), b.get_frame(0)
    m = tot = n = 0
    for pl in range(a.format.num_planes):
        for y in range(a.height):
            for x in range(a.width):
                d = abs(fa[pl][y, x] - fb[pl][y, x]) * scale
                m = max(m, d)
                tot += d
                n += 1
    return m, tot / n


CASES = [
    ("2020cl t709 p2020", "2020cl", "709", "2020", "2020ncl"),
    ("2020cl t2020_10 p2020", "2020cl", "2020_10", "2020", "2020ncl"),
    ("chromancl p709", "chromancl", None, "709", "709"),
    ("chromancl p2020", "chromancl", None, "2020", "2020ncl"),
    ("chromancl p170m", "chromancl", None, "170m", "170m"),
    ("chromancl p470bg", "chromancl", None, "470bg", "470bg"),
    ("chromacl t709 p709", "chromacl", "709", "709", "709"),
    ("chromacl t709 p170m", "chromacl", "709", "170m", "170m"),
    ("ictcp tPQ p2020", "ictcp", "st2084", "2020", "2020ncl"),
    ("ictcp tHLG p2020", "ictcp", "std-b67", "2020", "2020ncl"),
]


def section2_3():
    print("== 2. exact vs stand-in (random 8-bit RGB -> 10-bit limited 4:4:4 with the exact parameters)")
    content = rgb_content()
    for name, m, t, p, stand in CASES:
        src = core.resize.Point(content, format=vs.YUV444P10, range_s="limited", **kw(m, t, p, "out"))
        src = core.std.RemoveFrameProps(src, props=["_Matrix", "_Transfer", "_Primaries", "_Range", "_ColorRange"])
        rgb = core.resize.Bicubic(src, format=vs.RGBS, range_in_s="limited", **kw(m, t, p, "in"))
        back = core.resize.Bicubic(rgb, format=vs.YUV444P10, range_s="limited", dither_type="none",
                                   **kw(m, t, p, "out"))
        rt, _ = max_diff(src, back)
        rgb_s = core.resize.Bicubic(src, format=vs.RGBS, matrix_in_s=stand, range_in_s="limited")
        dm, dmean = max_diff(rgb, rgb_s, 255)
        greys = []
        for v in (0, 16, 128, 255):
            e = core.resize.Point(swatch([v] * 3), format=vs.YUV444P10, range_s="limited", **kw(m, t, p, "out"))
            greys.append(e.get_frame(0)[0][0, 0])
        print(f"{name:24} round trip max {rt} code(s); vs {stand}: max {dm:.1f}, mean {dmean:.2f} (8-bit RGB);"
              f" grey 0/16/128/255 -> Y' {greys}")
    print("== 3. BT.2020 CL keeps grey: Y' = R' for R=G=B; 10-bit limited 64 + 876 * v/255:",
          [round(64 + 876 * v / 255) for v in (0, 16, 128, 255)])
    v = (128 / 255) ** 2.4
    print("   zimg's 434 for 128 = BT.709 OETF of (128/255)^2.4 (display EOTF in, OETF out):",
          round(64 + 876 * (1.099 * v ** 0.45 - 0.099), 1))


# --- closed forms ------------------------------------------------------------

def krkb(prim):
    (xr, yr), (xg, yg), (xb, yb) = prim
    xw, yw = 0.3127, 0.3290
    zr, zg, zb, zw = 1 - xr - yr, 1 - xg - yg, 1 - xb - yb, 1 - xw - yw
    den = yw * (xr * (yg * zb - yb * zg) + xg * (yb * zr - yr * zb) + xb * (yr * zg - yg * zr))
    kr = yr * (xw * (yg * zb - yb * zg) + yw * (xb * zg - xg * zb) + zw * (xg * yb - xb * yg)) / den
    kb = yb * (xw * (yr * zg - yg * zr) + yw * (xg * zr - xr * zg) + zw * (xr * yg - xg * yr)) / den
    return kr, kb


def ycc(rgb, kr, kb):
    r, g, b = [c / 255 for c in rgb]
    y = kr * r + (1 - kr - kb) * g + kb * b
    return [round(64 + 876 * y), round(512 + 896 * (b - y) / (2 * (1 - kb))),
            round(512 + 896 * (r - y) / (2 * (1 - kr)))]


m1, m2, c1, c2, c3 = 2610 / 16384, 2523 / 4096 * 128, 3424 / 4096, 2413 / 4096 * 32, 2392 / 4096 * 32
A = 0.17883277
B = 1 - 4 * A
C = 0.5 - A * math.log(4 * A)


def pq_eotf(e):
    p = e ** (1 / m2)
    return (max(p - c1, 0) / (c2 - c3 * p)) ** (1 / m1)


def pq_oetf(y):
    p = y ** m1
    return ((c1 + c2 * p) / (1 + c3 * p)) ** m2


def hlg_oetf(e):
    return math.sqrt(3 * e) if e <= 1 / 12 else A * math.log(12 * e - B) + C


def hlg_inv(x):
    return x * x / 3 if x <= 0.5 else (math.exp((x - C) / A) + B) / 12


def ictcp(rgb, lin, enc, ct, cp):
    R, G, Bl = [lin(v / 255) for v in rgb]
    L = enc((1688 * R + 2146 * G + 262 * Bl) / 4096)
    M = enc((683 * R + 2951 * G + 462 * Bl) / 4096)
    S = enc((99 * R + 309 * G + 3688 * Bl) / 4096)
    i = 0.5 * L + 0.5 * M
    return [round(64 + 876 * i), round(512 + 896 * (ct[0] * L + ct[1] * M + ct[2] * S) / 4096),
            round(512 + 896 * (cp[0] * L + cp[1] * M + cp[2] * S) / 4096)]


PQ_CT, PQ_CP = (6610, -13613, 7003), (17933, -17390, -543)
HLG_CT, HLG_CP = (3625, -7465, 3840), (9500, -9212, -288)
PRIM = {"470bg": ((0.64, 0.33), (0.29, 0.60), (0.15, 0.06)),
        "170m": ((0.630, 0.340), (0.310, 0.595), (0.155, 0.070))}


def zimg(col, **k):
    f = core.resize.Point(swatch(col), format=vs.YUV444P10, range_s="limited", **k).get_frame(0)
    return [f[p][0, 0] for p in range(3)]


def section4():
    print("== 4. against the standards' closed forms (10-bit limited codes), 300 random colours each")
    rnd = random.Random(3)
    cols = [[rnd.randint(0, 255) for _ in range(3)] for _ in range(300)]
    rows = [
        ("chromancl 470bg (H.273 eq. 39-40)", lambda c: ycc(c, *krkb(PRIM["470bg"])),
         dict(matrix_s="chromancl", primaries_in_s="470bg", primaries_s="470bg")),
        ("chromancl 170m (H.273 eq. 39-40)", lambda c: ycc(c, *krkb(PRIM["170m"])),
         dict(matrix_s="chromancl", primaries_in_s="170m", primaries_s="170m")),
        ("ictcp PQ (BT.2100)", lambda c: ictcp(c, pq_eotf, pq_oetf, PQ_CT, PQ_CP),
         dict(matrix_s="ictcp", transfer_in_s="st2084", transfer_s="st2084", primaries_in_s="2020", primaries_s="2020")),
        ("ictcp HLG (BT.2100, scene-referred)", lambda c: ictcp(c, hlg_inv, hlg_oetf, HLG_CT, HLG_CP),
         dict(matrix_s="ictcp", transfer_in_s="std-b67", transfer_s="std-b67", primaries_in_s="2020", primaries_s="2020")),
    ]
    for name, ref, k in rows:
        worst = tot = worst_s = tot_s = 0
        for c in cols:
            r = ref(c)
            z = zimg(c, **k)
            s = zimg(c, matrix_s="2020ncl" if "ictcp" in name else ("470bg" if "470bg" in name else "170m"))
            d = max(abs(a - b) for a, b in zip(r, z))
            ds = max(abs(a - b) for a, b in zip(r, s))
            worst, tot, worst_s, tot_s = max(worst, d), tot + d, max(worst_s, ds), tot_s + ds
        print(f"{name:38} zimg exact: max {worst}, mean {tot / len(cols):.2f};"
              f" stand-in: max {worst_s}, mean {tot_s / len(cols):.1f}")


def section5():
    print("== 5. primaries names for chromancl")
    yuv = core.std.BlankClip(width=96, height=64, format=vs.YUV420P10, color=[500, 400, 600], length=1)
    for name in ["709", "470m", "470bg", "170m", "240m", "film", "2020", "st428", "xyz",
                 "st431-2", "st432-1", "jedec-p22", "ebu3213"]:
        ok = runs(lambda: core.resize.Spline36(yuv, format=vs.RGBS, matrix_in_s="chromancl",
                                               primaries_in_s=name, primaries_s=name))
        print(f"{name:10} {'ok' if ok else 'FAIL'}")


print(str(core).splitlines()[2].strip())
section1()
section2_3()
section4()
section5()
