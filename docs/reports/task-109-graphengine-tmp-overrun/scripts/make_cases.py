#!/usr/bin/env python3
"""Write cases.tsv: the graphs tmp_overrun.c builds (task #109).

They are the resize calls that aborted on the 1.18.0-rc3 Linux bundle:
worker/tests/zimg_colorspace_test.rs (an RGB swatch and random content to
YUV, YUV to RGBS and back, Colourisation's YUV444PS path), and the kinds of
call the failing sweep rows make: Deband's working depth (4:2:0 to 16 bits
and back with error diffusion), BM3D's GRAY planes at 16 bits, Descale's
luma resampling, the BT.601 -> BT.709 conversion, and an SD -> HD resize.
Each at 96x64, 98x64 (odd chroma width) and 720x480, progressive and
interlaced (two field graphs, as VapourSynth builds them).

Usage: make_cases.py > cases.tsv
"""

SIZES = [(96, 64), (98, 64), (720, 480)]
YUV = ["yuv420p8", "yuv420p10", "yuv422p10", "yuv444p16"]


def cases():
    out = []

    def add(name, src, ssize, dst, dsize, filt, dither, field):
        out.append((name, src, "%dx%d" % ssize, dst, "%dx%d" % dsize, filt, dither, field))

    # zimg_colorspace_test.rs, 1: the 4x4 border swatch (progressive only).
    for fmt in YUV:
        add("swatch-%s" % fmt, "rgb24", (4, 4), fmt + ":709:l", (4, 4), "point", "none", "p")

    for w, h in SIZES:
        for field in "pi":
            tag = "%dx%d%s" % (w, h, field)
            for fmt in YUV:
                # zimg_colorspace_test.rs, 2: content to YUV, to RGBS and back.
                add("cs-to-%s-%s" % (fmt, tag), "rgb24", (w, h), fmt + ":709:l", (w, h), "point", "none", field)
                add("cs-to-rgbs-%s-%s" % (fmt, tag), fmt + ":709:l", (w, h), "rgbs", (w, h), "bicubic", "none", field)
                add("cs-from-rgbs-%s-%s" % (fmt, tag), "rgbs", (w, h), fmt + ":709:l", (w, h), "bicubic", "none", field)
                # Colourisation: float YUV444 to the source format.
                add("colorize-%s-%s" % (fmt, tag), "yuv444ps:709:l", (w, h), fmt + ":709:l", (w, h),
                    "bicubic", "error_diffusion", field)
            add("cs-rgbs-yuv444ps-%s" % tag, "rgbs", (w, h), "yuv444ps:709:l", (w, h), "bilinear", "none", field)
            # Deband's working depth: up to 16 bits, back down dithered.
            for fmt in ("yuv420p8", "yuv420p10", "yuv422p10"):
                add("deband-up-%s-%s" % (fmt, tag), fmt + ":709:l", (w, h), "yuv420p16:709:l" if fmt.startswith("yuv420") else "yuv422p16:709:l",
                    (w, h), "point", "none", field)
            add("deband-down-%s" % tag, "yuv420p16:709:l", (w, h), "yuv420p8:709:l", (w, h), "point", "error_diffusion", field)
            # BM3D: each plane as GRAY, to 16 bits and back.
            add("bm3d-up-%s" % tag, "gray8:unspec:l", (w, h), "gray16:unspec:l", (w, h), "point", "none", field)
            add("bm3d-down-%s" % tag, "gray16:unspec:l", (w, h), "gray8:unspec:l", (w, h), "point", "error_diffusion", field)
            # Descale's re-upscale: luma resampled.
            add("descale-%s" % tag, "gray16:unspec:l", (w * 2 // 3 // 2 * 2, h * 2 // 3 // 2 * 2), "gray16:unspec:l", (w, h),
                "spline36", "none", field)
            # Crop & Resize's BT.601 -> BT.709 matrix change, same size.
            add("bt709-%s" % tag, "yuv420p8:470bg:l", (w, h), "yuv420p8:709:l", (w, h), "bicubic", "none", field)
    # SD -> HD with the matrix change, and a plain downscale.
    for field in "pi":
        add("resize-sd-hd-%s" % field, "yuv420p8:470bg:l", (720, 480), "yuv420p8:709:l", (1280, 720), "spline36", "none", field)
        add("resize-down-%s" % field, "yuv420p8:709:l", (720, 480), "yuv420p8:709:l", (352, 240), "bicubic", "none", field)
    return out


if __name__ == "__main__":
    print("# name\tsrc\tsrc size\tdst\tdst size\tfilter\tdither\tfield  (make_cases.py)")
    for c in cases():
        print("\t".join(c))
