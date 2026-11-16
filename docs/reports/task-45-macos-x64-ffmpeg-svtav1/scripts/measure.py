#!/usr/bin/env python3
"""Every number in the task #45 report: evermeet 9.0.1 vs martin-riedl 9.0.2.

Usage: python3 -I measure.py DIR      (DIR as filled by fetch.sh)
Scratch files go to $WORK (default: a new temp directory). Writes
results.json next to this script.

On Apple Silicon the x86_64 binaries run under Rosetta 2 (`arch -x86_64`),
which translates AVX2: SIMD paths are the AVX2 ones, and speed is not an
Intel Mac's.
"""

import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
RES = os.path.join(REPO, "Tests", "TestResources")
DIR = os.path.abspath(sys.argv[1])
WORK = os.environ.get("WORK") or tempfile.mkdtemp(prefix="task45-")
os.makedirs(WORK, exist_ok=True)

BUILDS = {"evermeet": os.path.join(DIR, "evermeet"), "mr": os.path.join(DIR, "mr")}
PREFIX = ["arch", "-x86_64"] if platform.machine() == "arm64" else []


def ff(build, *args, tool="ffmpeg", env=None, check=True):
    cmd = PREFIX + [os.path.join(BUILDS[build], tool), "-hide_banner", *args]
    r = subprocess.run(cmd, capture_output=True, env=env)
    if check and r.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)}\n{r.stderr.decode(errors='replace')[-2000:]}")
    return r


def md5(path):
    return hashlib.md5(open(path, "rb").read()).hexdigest()


results = {"host": f"{platform.machine()} {platform.mac_ver()[0]}", "rosetta": bool(PREFIX)}

# --- 1. Static checks -------------------------------------------------------
probe = {}
for b in BUILDS:
    exe = os.path.join(BUILDS[b], "ffmpeg")
    ver = ff(b, "-version").stdout.decode()
    lines = ver.splitlines()
    loads = subprocess.run(["otool", "-l", exe], capture_output=True, text=True).stdout
    m = re.search(r"cmd LC_BUILD_VERSION.*?minos (\S+)", loads, re.S) or \
        re.search(r"cmd LC_VERSION_MIN_MACOSX.*?version (\S+)", loads, re.S)
    deps = subprocess.run(["otool", "-L", exe], capture_output=True, text=True).stdout.splitlines()[1:]
    deps = [d.strip().split(" (")[0] for d in deps]
    # check-macho-refs.py walks a directory: give it one holding just these two.
    tree = os.path.join(WORK, f"refs-{b}")
    shutil.rmtree(tree, ignore_errors=True)
    os.makedirs(tree)
    for t in ("ffmpeg", "ffprobe"):
        shutil.copy2(os.path.join(BUILDS[b], t), tree)
    refs = subprocess.run([sys.executable, "-I", os.path.join(REPO, "Scripts", "check-macho-refs.py"), tree],
                          capture_output=True, text=True)
    simd = subprocess.run([sys.executable, "-I", os.path.join(REPO, "Scripts", "check-load-time-simd.py"),
                           "--depth", "0", exe], capture_output=True, text=True)
    sizes = {t: os.path.getsize(os.path.join(BUILDS[b], t)) for t in ("ffmpeg", "ffprobe")}
    zips = {t: os.path.getsize(os.path.join(BUILDS[b], t + ".zip")) for t in ("ffmpeg", "ffprobe")}
    probe[b] = {
        "version": lines[0],
        "compiler": lines[1],
        "configure": lines[2],
        "series": re.search(r"version n?(\d+\.\d+)", lines[0]).group(1),
        "minos": m.group(1) if m else None,
        "dependencies": deps,
        "outside_system": [d for d in deps if not d.startswith(("/usr/lib/", "/System/"))],
        "check_macho_refs": {"exit": refs.returncode, "output": refs.stdout.strip()},
        # Paths reduced to <build>/ffmpeg so no scratch path reaches results.json.
        "load_time_simd_depth0": {"exit": simd.returncode,
                                  "output": simd.stdout.strip().replace(BUILDS[b], b)},
        "bytes": sizes,
        "zip_bytes": zips,
    }
results["probe"] = probe

# --- 2. Capabilities ---------------------------------------------------------
def listing(b, kind):
    out = ff(b, f"-{kind}").stdout.decode().splitlines()
    names = set()
    started = False
    for line in out:
        if line.strip().startswith("---") or line.strip() == "--":
            started = True
            continue
        parts = line.split()
        if kind in ("muxers", "demuxers"):
            if started and len(parts) >= 2:
                names.add(parts[1])
        elif started and len(parts) >= 2:
            names.add(parts[1])
    return names


caps = {}
for kind in ("encoders", "decoders", "filters", "muxers", "demuxers"):
    e, m = listing("evermeet", kind), listing("mr", kind)
    caps[kind] = {"only_evermeet": sorted(e - m), "only_mr": sorted(m - e)}

# Is anything VapourBox's code names among what is lost?
lost = {n for k in caps.values() for n in k["only_evermeet"]}
used = {}
for root in ("worker/src", "worker/templates", "app/lib", "app/assets"):
    for dirpath, _, files in os.walk(os.path.join(REPO, root)):
        for f in files:
            if f.endswith(".g.dart"):
                continue
            text = open(os.path.join(dirpath, f), errors="ignore").read()
            for n in lost:
                if re.search(r"(?<![\w-])" + re.escape(n) + r"(?![\w-])", text):
                    used.setdefault(n, []).append(os.path.relpath(os.path.join(dirpath, f), REPO))
caps["lost_names_used_by_vapourbox"] = used
# The filters the worker builds into -vf / -af chains and the decode paths.
needed = ["aresample", "loudnorm", "afftdn", "adeclick", "adeclip", "alimiter", "highpass",
          "bandreject", "pan", "adelay", "apad", "atrim", "asetpts", "asetrate", "zscale",
          "tonemap", "subtitles", "fps", "trim", "setparams", "setpts", "settb", "setsar",
          "setdar", "scale", "format", "crop", "select", "signalstats"]
caps["needed_filters_missing"] = {b: sorted(set(needed) - listing(b, "filters")) for b in BUILDS}
results["capabilities"] = caps

# --- 3. Encoder output -------------------------------------------------------
SRC = ["-f", "lavfi", "-i", "testsrc2=size=720x576:rate=25:duration=2",
       "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=2"]
ENCODERS = {
    "libx264 CRF 18 medium": ["-map", "0:v", "-pix_fmt", "yuv420p", "-c:v", "libx264", "-crf", "18", "-preset", "medium"],
    "libx265 CRF 20 medium 10-bit": ["-map", "0:v", "-pix_fmt", "yuv420p10le", "-c:v", "libx265", "-crf", "20",
                                     "-preset", "medium", "-x265-params", "pools=1:frame-threads=1"],
    **{f"prores_ks profile {p}": ["-map", "0:v", "-pix_fmt", "yuv444p10le" if p >= 4 else "yuv422p10le",
                                  "-c:v", "prores_ks", "-profile:v", str(p)] for p in range(5)},
    "ffv1 level 3": ["-map", "0:v", "-pix_fmt", "yuv420p", "-c:v", "ffv1", "-level", "3"],
    "huffyuv": ["-map", "0:v", "-pix_fmt", "yuv422p", "-c:v", "huffyuv"],
    "ffvhuff": ["-map", "0:v", "-pix_fmt", "yuv420p", "-c:v", "ffvhuff"],
    "v210": ["-map", "0:v", "-pix_fmt", "yuv422p10le", "-c:v", "v210"],
    "aac 192k": ["-map", "1:a", "-c:a", "aac", "-b:a", "192k"],
    "libmp3lame 192k": ["-map", "1:a", "-c:a", "libmp3lame", "-b:a", "192k"],
    "ac3 192k": ["-map", "1:a", "-c:a", "ac3", "-b:a", "192k"],
    "libopus 128k": ["-map", "1:a", "-c:a", "libopus", "-b:a", "128k"],
    "flac": ["-map", "1:a", "-c:a", "flac"],
    "pcm_s24le": ["-map", "1:a", "-c:a", "pcm_s24le"],
}
enc = {}
for name, args in ENCODERS.items():
    row = {}
    for b in BUILDS:
        out = os.path.join(WORK, f"enc-{b}-{re.sub(r'[^a-z0-9]+', '_', name.lower())}.nut")
        ff(b, "-y", *SRC, "-fflags", "+bitexact", "-flags", "+bitexact", "-threads", "1", *args, out)
        # The packets as encoded, and what a decoder (always mr's) makes of them.
        packets = ff("mr", "-i", out, "-map", "0", "-c", "copy", "-f", "streamhash", "-hash", "md5", "-")
        decoded = ff("mr", "-i", out, "-map", "0", "-f", "framemd5", "-")
        row[b] = {"bitstream_md5": packets.stdout.decode().strip().split("=")[-1],
                  "decoded_md5": hashlib.md5(b"\n".join(
                      l for l in decoded.stdout.splitlines() if not l.startswith(b"#"))).hexdigest(),
                  "bytes": os.path.getsize(out)}
    row["bitstream_identical"] = row["evermeet"]["bitstream_md5"] == row["mr"]["bitstream_md5"]
    row["decoded_identical"] = row["evermeet"]["decoded_md5"] == row["mr"]["decoded_md5"]
    enc[name] = row
results["encoder_bitstreams"] = enc

# Library versions behind the encoders that differ.
def lib_versions(b):
    v = {}
    h264 = ff(b, "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=64x64:duration=0.2",
              "-c:v", "libx264", "-f", "h264", "-").stdout
    m = re.search(rb"x264 - core (\d+)( r\d+ [0-9a-f]+)?", h264)
    v["x264"] = m.group(0).decode() if m else None
    r = ff(b, "-f", "lavfi", "-i", "testsrc2=size=64x64:duration=0.2", "-c:v", "libx265", "-f", "null", "-")
    m = re.search(rb"HEVC encoder version (\S+)", r.stderr)
    v["x265"] = m.group(1).decode() if m else None
    mp3 = ff(b, "-loglevel", "error", "-f", "lavfi", "-i", "sine=duration=1", "-c:a", "libmp3lame",
             "-b:a", "128k", "-f", "mp3", "-").stdout
    m = re.search(rb"LAME\d\.\d+", mp3)
    v["lame"] = m.group(0).decode() if m else None
    r = ff(b, "-f", "lavfi", "-i", "testsrc2=size=64x64:duration=0.2", "-c:v", "libsvtav1", "-f", "null", "-",
           check=False)
    m = re.search(rb"SVT-AV1 Encoder Lib (v\S+)", r.stderr)
    v["svt-av1"] = m.group(1).decode() if m else None
    return v


results["library_versions"] = {b: lib_versions(b) for b in BUILDS}

# --- 4. Quality of the encoders that differ, on real fixtures -----------------
FIXTURES = ["small_clip.mp4", "pal-sd-25.mov", "interlaced_test.avi"]
FRAMES = "100"


def score(ref, dist):
    # Always scored by the same binary (mr) so only the encodes differ.
    # Pair frames by index: the containers' time bases differ (MKV 1/1000,
    # NUT the stream's), and timestamp sync paired the wrong frames.
    pair = "settb=1/25,setpts=N"
    r = ff("mr", "-i", dist, "-i", ref, "-lavfi",
           f"[0:v]{pair},split[a1][a2];[1:v]{pair},split[b1][b2];[a1][b1]psnr;[a2][b2]ssim",
           "-f", "null", "-")
    err = r.stderr.decode()
    psnr = re.search(r"PSNR y:(\S+) .*?average:(\S+)", err)
    ssim = re.search(r"SSIM .*?All:(\S+)", err)
    return {"psnr_y": float(psnr.group(1)), "psnr_avg": float(psnr.group(2)), "ssim_all": float(ssim.group(1))}


quality = {}
for fx in FIXTURES:
    src = os.path.join(RES, fx)
    # A lossless reference of exactly the frames encoded.
    ref = os.path.join(WORK, f"ref-{fx}.nut")
    ff("mr", "-y", "-i", src, "-map", "0:v:0", "-frames:v", FRAMES, "-c:v", "ffv1", ref)
    for codec, args in {"libx264 CRF 18": ["-c:v", "libx264", "-crf", "18", "-preset", "medium"],
                        "libx265 CRF 20": ["-c:v", "libx265", "-crf", "20", "-preset", "medium"]}.items():
        for b in BUILDS:
            out = os.path.join(WORK, f"{b}-{codec.split()[0]}-{fx}.mkv")
            ff(b, "-y", "-i", ref, "-map", "0:v", *args, out)
            q = score(ref, out)
            q["bytes"] = os.path.getsize(out)
            dec_ = ff("mr", "-i", out, "-f", "framemd5", "-").stdout
            q["decoded_md5"] = hashlib.md5(b"\n".join(
                l for l in dec_.splitlines() if not l.startswith(b"#"))).hexdigest()
            quality.setdefault(fx, {}).setdefault(codec, {})[b] = q
results["quality"] = quality

# MP3: same LAME on both; how far apart are the two decodes?
mp3 = {}
src = os.path.join(RES, "small_clip.mp4")
pcm = {}
for b in BUILDS:
    out = os.path.join(WORK, f"{b}.mp3")
    ff(b, "-y", "-i", src, "-map", "0:a:0", "-t", "20", "-c:a", "libmp3lame", "-b:a", "192k", out)
    raw = ff("mr", "-i", out, "-f", "s16le", "-ac", "1", "-").stdout
    pcm[b] = raw
    mp3[b] = {"bytes": os.path.getsize(out)}
import array
a, c = array.array("h", pcm["evermeet"]), array.array("h", pcm["mr"])
n = min(len(a), len(c))
sig = sum(x * x for x in a[:n]) / n
diff = sum((x - y) ** 2 for x, y in zip(a[:n], c[:n])) / n
import math
mp3["samples_compared"] = n
mp3["identical_decode"] = diff == 0
mp3["difference_db_below_signal"] = None if diff == 0 else round(10 * math.log10(sig / diff), 1)
mp3["max_abs_sample_difference"] = max(abs(x - y) for x, y in zip(a[:n], c[:n]))
results["mp3"] = mp3

# --- 5. Decoders: every fixture, both builds ---------------------------------
dec = {}
media = sorted(f for f in os.listdir(RES) if os.path.isfile(os.path.join(RES, f))
               and not f.endswith((".sh", ".json", ".onnx", ".md")))
for fx in media:
    row = {}
    for b in BUILDS:
        r = ff(b, "-i", os.path.join(RES, fx), "-map", "0", "-map", "-0:s?", "-map", "-0:d?",
               "-f", "framemd5", "-", check=False)
        body = [l for l in r.stdout.decode().splitlines() if not l.startswith("#")]
        row[b] = {"exit": r.returncode, "frames": len(body),
                  "md5": hashlib.md5("\n".join(body).encode()).hexdigest()}
    row["identical"] = row["evermeet"] == row["mr"]
    dec[fx] = row
results["decoders"] = dec

# --- 6. HDR display chain and subtitle burn-in --------------------------------
# An HDR10 clip made with zscale (PQ, BT.2020), then the worker's display
# tone-map string (ColorMetadata::display_tonemap_filter) through each build.
hdr = os.path.join(WORK, "hdr10.mkv")
ff("mr", "-y", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25:duration=1",
   "-vf", "setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv,"
   "zscale=t=smpte2084:p=bt2020:m=bt2020nc:r=tv:npl=400,format=yuv420p10le",
   "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc",
   "-c:v", "ffv1", hdr)
TONEMAP = ("setparams=colorspace=bt2020nc:color_primaries=bt2020:color_trc=smpte2084:range=tv,"
           "zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,"
           "tonemap=tonemap=hable:desat=0,zscale=t=bt709:r=full,"
           "format=rgb24,setparams=colorspace=gbr")
extra = {}
for b in BUILDS:
    r = ff(b, "-i", hdr, "-vf", TONEMAP, "-f", "framemd5", "-")
    extra.setdefault("hdr_tonemap", {})[b] = hashlib.md5(
        "\n".join(l for l in r.stdout.decode().splitlines() if not l.startswith("#")).encode()).hexdigest()
srt = os.path.join(WORK, "t.srt")
open(srt, "w").write("1\n00:00:00,000 --> 00:00:02,000\nHello burn-in test\n")
for b in BUILDS:
    r = ff(b, "-f", "lavfi", "-i", "color=black:size=640x360:duration=1", "-vf",
           f"subtitles='{srt}'", "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "gray", "-")
    extra.setdefault("burn_in_bright_pixels", {})[b] = sum(1 for x in r.stdout if x > 128)
    extra.setdefault("burn_in_md5", {})[b] = hashlib.md5(r.stdout).hexdigest()
results["filters"] = extra

# --- 7. AV1 through the new build --------------------------------------------
av1 = {}
ref = os.path.join(WORK, "ref-small_clip.mp4.nut")
svt_env = dict(os.environ, SVT_LOG="2")
for depth, pix in (("8-bit", "yuv420p"), ("10-bit", "yuv420p10le")):
    for ext in ("mp4", "mkv"):
        out = os.path.join(WORK, f"av1-{depth}.{ext}")
        t = time.time()
        ff("mr", "-y", "-i", ref, "-map", "0:v", "-pix_fmt", pix, "-c:v", "libsvtav1",
           "-preset", "6", "-crf", "24", out, env=svt_env)
        secs = time.time() - t
        info = json.loads(ff("mr", "-v", "error", "-select_streams", "v:0", "-count_frames",
                             "-show_entries", "stream=codec_name,pix_fmt,nb_read_frames",
                             "-of", "json", out, tool="ffprobe").stdout)["streams"][0]
        q = score(ref, out)
        av1[f"{depth} {ext}"] = {**info, **q, "bytes": os.path.getsize(out),
                                 "fps_under_rosetta" if PREFIX else "fps": round(int(FRAMES) / secs, 1)}
# HDR10 metadata through -svtav1-params, as HdrMetadata::svtav1_params writes it.
params = ("mastering-display=G(0.265,0.69)B(0.15,0.06)R(0.68,0.32)WP(0.3127,0.329)L(1000,0.0001)"
          ":content-light=1000,400")
out = os.path.join(WORK, "av1-hdr.mkv")
ff("mr", "-y", "-i", hdr, "-c:v", "libsvtav1", "-preset", "8", "-crf", "30", "-svtav1-params", params,
   "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc", out, env=svt_env)
sd = json.loads(ff("mr", "-v", "error", "-select_streams", "v:0", "-read_intervals", "%+#1",
                   "-show_frames", "-show_entries", "frame=side_data_list", "-of", "json", out,
                   tool="ffprobe").stdout)
av1["hdr10_side_data"] = sd["frames"][0].get("side_data_list") if sd.get("frames") else None
av1["evermeet_has_libsvtav1"] = "libsvtav1" not in caps["encoders"]["only_mr"]
results["av1"] = av1

with open(os.path.join(HERE, "results.json"), "w") as f:
    json.dump(results, f, indent=2, sort_keys=False)
print(json.dumps({k: results[k] for k in ("encoder_bitstreams", "library_versions", "mp3")}, indent=1))
print("quality decodes identical:", all(len({q[b]["decoded_md5"] for b in BUILDS}) == 1
      for fx in quality.values() for q in fx.values()))
print("decoders identical:", sum(r["identical"] for r in dec.values()), "/", len(dec))
