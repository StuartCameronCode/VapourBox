#!/usr/bin/env python3
"""Which decodes fail on `reserved` colour tags, and which neutraliser fixes
them without changing pixels.

Usage: python3 -I probe_tag_rules.py <ffmpeg> <ffprobe> <workdir> [real_clip.mov]

Builds every fixture it needs in <workdir> from ffmpeg's testsrc2 (no repo
files), prints one line per measurement. With a real clip, also runs the
call-site table on it (its own size is read with ffprobe).
"""
import json, os, struct, subprocess, sys

FF, FP, WD = sys.argv[1:4]
CLIP = sys.argv[4] if len(sys.argv) > 4 else None
os.makedirs(WD, exist_ok=True)
N2 = "setparams=color_primaries=unknown:color_trc=unknown"
N3 = N2 + ":colorspace=unknown"


def ff(*args):
    r = subprocess.run([FF, "-v", "error", "-y", *args], capture_output=True, text=True)
    return r.returncode, r.stderr.strip().splitlines()[0][:110] if r.stderr.strip() else ""


def w(name):
    return os.path.join(WD, name)


def tags(path):
    out = subprocess.run([FP, "-v", "error", "-select_streams", "v:0", "-show_entries",
                          "stream=pix_fmt,width,height,color_space,color_primaries,color_transfer",
                          "-of", "json", path], capture_output=True, text=True).stdout
    return json.loads(out)["streams"][0]


def raw(path, fmt, vf=None, frames=1, ss=None):
    out = w("probe.raw")
    if os.path.exists(out):
        os.remove(out)
    args = (["-ss", str(ss)] if ss else []) + ["-apply_cropping", "codec", "-i", path,
            "-map", "0:v:0", "-frames:v", str(frames)]
    if vf:
        args += ["-vf", vf]
    code, err = ff(*args, "-f", "rawvideo", "-pix_fmt", fmt, out)
    return (open(out, "rb").read() if code == 0 and os.path.exists(out) else None), err


def retag(src, dst, spec):
    return ff("-i", src, "-map", "0", "-c", "copy", "-bsf:v", "prores_metadata=" + spec, dst)


print("== FFmpeg:", subprocess.run([FF, "-version"], capture_output=True, text=True).stdout.splitlines()[0])

# Fixtures.
ff("-f", "lavfi", "-i", "testsrc2=s=720x486:r=30000/1001:d=0.2", "-c:v", "prores_ks",
   "-profile:v", "2", "-pix_fmt", "yuv422p10le", w("base.mov"))
ff("-f", "lavfi", "-i", "testsrc2=s=320x240:r=25:d=0.2", "-c:v", "prores_ks",
   "-profile:v", "4", "-pix_fmt", "yuva444p10le", w("base4444a.mov"))

print("\n== prores_metadata BSF values -> what ffprobe reports")
for spec in ["color_primaries=unknown:color_trc=unknown", "color_primaries=2", "color_primaries=3",
             "colorspace=0", "colorspace=1:color_primaries=unknown:color_trc=unknown"]:
    dst = w("bsf.mov")
    code, err = retag(w("base.mov"), dst, spec)
    t = tags(dst) if code == 0 else {}
    print(f"  {spec:55} -> " + (f"csp={t.get('color_space')} prim={t.get('color_primaries')} trc={t.get('color_transfer')}"
                                 if code == 0 else f"refused ({err})"))

retag(w("base.mov"), w("reserved.mov"), "color_primaries=unknown:color_trc=unknown")
retag(w("base.mov"), w("v709.mov"), "colorspace=bt709:color_primaries=bt709:color_trc=bt709")
retag(w("base.mov"), w("m709_reserved.mov"), "colorspace=bt709:color_primaries=unknown:color_trc=unknown")
retag(w("base4444a.mov"), w("reserved4444a.mov"), "color_primaries=unknown:color_trc=unknown")

print("\n== Which neutraliser is enough (reserved primaries + transfer, yuv422p10le -> rgb24)")
for vf in [None, "setparams=color_primaries=unknown", "setparams=color_trc=unknown", N2, N3]:
    data, err = raw(w("reserved.mov"), "rgb24", vf)
    print(f"  {str(vf):70} -> {'OK' if data else 'FAILS: ' + err}")

print("\n== Fixed decode vs the untagged original (bit-exact?)")
for fmt in ["yuv444p", "gray16le", "rgb24"]:
    a, _ = raw(w("reserved.mov"), fmt, N2)
    b, _ = raw(w("base.mov"), fmt)
    print(f"  {fmt:9} identical: {a == b}")

print("\n== A valid matrix must be kept: bt709 matrix, reserved prim/trc, rgb24")
kept, _ = raw(w("m709_reserved.mov"), "rgb24", N2)
ref709, _ = raw(w("base.mov"), "rgb24", "setparams=colorspace=bt709")
print(f"  matrix kept == untagged read as 709: {kept == ref709}")

print("\n== Clearing a VALID tag (bt709 everywhere): does the decode change?")
for fmt in ["yuv444p", "gray16le"]:
    a, _ = raw(w("v709.mov"), fmt)
    for vf in ["setparams=color_primaries=unknown:color_trc=unknown", "setparams=colorspace=unknown"]:
        b, _ = raw(w("v709.mov"), fmt, vf)
        if a == b:
            print(f"  {fmt:9} {vf:55} identical")
            continue
        if fmt == "gray16le":
            A = struct.unpack(f"<{len(a)//2}H", a)
            B = struct.unpack(f"<{len(b)//2}H", b)
            d = [abs(x - y) for x, y in zip(A, B)]
            print(f"  {fmt:9} {vf:55} DIFFERS: max {max(d)}/65535 = {max(d)/257:.1f} 8-bit levels, "
                  f"mean {sum(d)/len(d)/257:.1f}")
        else:
            print(f"  {fmt:9} {vf:55} DIFFERS")

print("\n== ProRes 4444 with alpha: the encode decoder converts yuva444p12le -> yuv444p12le")
print("  probed:", tags(w("reserved4444a.mov"))["pix_fmt"])
for vf in [None, N2]:
    data, err = raw(w("reserved4444a.mov"), "yuv444p12le", vf, frames=3)
    print(f"  {str(vf):55} -> {'OK' if data else 'FAILS: ' + err}")
a, _ = raw(w("reserved4444a.mov"), "yuv444p12le", N2, frames=3)
b, _ = raw(w("base4444a.mov"), "yuv444p12le", None, frames=3)
print(f"  fixed == untagged original: {a == b}")

print("\n== gbr (ffprobe's RGB identity) is handled by swscale: clearing it changes nothing")
ff("-f", "lavfi", "-i", "testsrc2=s=320x240:r=25:d=0.2", "-c:v", "ffv1", "-pix_fmt", "gbrp", w("rgb.mkv"))
print("  probed matrix:", tags(w("rgb.mkv")).get("color_space"))
for fmt in ["yuv444p", "rgb24"]:
    a, _ = raw(w("rgb.mkv"), fmt)
    b, _ = raw(w("rgb.mkv"), fmt, "setparams=colorspace=unknown")
    print(f"  {fmt:8} identical: {a == b}")
code, err = ff("-f", "lavfi", "-i", "testsrc2=s=64x64:d=0.04", "-colorspace", "gbr", "-c:v", "ffv1", w("x.mkv"))
print(f"  -colorspace gbr accepted as an option: {code == 0} ({err})")

if CLIP:
    t = tags(CLIP)
    W, H = t["width"], t["height"]
    guard = f"crop=w='if(eq(iw\\,{W})\\,iw\\,0)':h='if(eq(ih\\,{H})\\,ih\\,0)':x=0:y=0:exact=1"
    print(f"\n== Real clip ({W}x{H} {t['pix_fmt']} csp={t.get('color_space')} prim={t.get('color_primaries')} "
          f"trc={t.get('color_transfer')}): each call site's decode, without and with the fix")
    sites = [
        ("app before frame (JPEG)", ["-ss", "10", "-apply_cropping", "codec", "-i", CLIP, "-frames:v", "1"],
         None, ["-q:v", "2", w("b.jpg")]),
        ("app thumbnail (scale=160:-1)", ["-ss", "10", "-apply_cropping", "codec", "-i", CLIP, "-vframes", "1"],
         "scale=160:-1", ["-q:v", "5", w("t.jpg")]),
        ("--detect-crop (yuv444p)", ["-ss", "10", "-apply_cropping", "codec", "-i", CLIP, "-map", "0:v:0", "-frames:v", "1"],
         guard, ["-f", "rawvideo", "-pix_fmt", "yuv444p", w("c.raw")]),
        ("--detect-native (gray16le)", ["-ss", "10", "-apply_cropping", "codec", "-i", CLIP, "-map", "0:v:0", "-frames:v", "1"],
         guard, ["-f", "rawvideo", "-pix_fmt", "gray16le", w("n.raw")]),
        ("preview/encode/noise-halo (own format)", ["-ss", "10", "-apply_cropping", "codec", "-i", CLIP, "-map", "0:v:0", "-frames:v", "2"],
         guard, ["-f", "rawvideo", "-pix_fmt", t["pix_fmt"], w("p.raw")]),
    ]
    for name, pre, vf, post in sites:
        res = []
        for fix in [None, N2]:
            chain = ",".join(x for x in [fix, vf] if x)
            code, err = ff(*pre, *(["-vf", chain] if chain else []), *post)
            res.append("OK" if code == 0 else f"exit {code}")
        print(f"  {name:42} today: {res[0]:9} with fix: {res[1]}")
