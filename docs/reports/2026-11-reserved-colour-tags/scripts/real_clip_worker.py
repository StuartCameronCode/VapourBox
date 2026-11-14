#!/usr/bin/env python3
"""Run the worker's detectors, a preview and a trimmed encode on a real clip,
the way the app does (job JSON carrying ffprobe's raw colour tags).

Usage: python3 -I real_clip_worker.py <worker> <deps/platform dir> <clip> <outdir>
macOS/Linux environment only (mirrors WorkerHarness.workerEnv).
"""
import json, os, subprocess, sys, time, uuid

WORKER, DEPS, CLIP, OUT = sys.argv[1:5]
os.makedirs(OUT, exist_ok=True)
FF = os.path.join(DEPS, "ffmpeg", "ffmpeg")
FP = os.path.join(DEPS, "ffmpeg", "ffprobe")

env = dict(os.environ)
env.update({
    "PYTHONHOME": os.path.join(DEPS, "python"),
    "PYTHONPATH": DEPS + ":" + os.path.join(DEPS, "python-packages"),
    "PYTHONNOUSERSITE": "1",
    "XDG_CONFIG_HOME": os.path.join(DEPS, "config"),
    "PATH": ":".join([os.path.join(DEPS, "python", "bin"), os.path.join(DEPS, "vapoursynth"),
                      os.path.join(DEPS, "ffmpeg"), env.get("PATH", "")]),
    "DYLD_LIBRARY_PATH": os.path.join(DEPS, "vapoursynth") + ":" + os.path.join(DEPS, "python", "lib"),
    "LD_LIBRARY_PATH": ":".join([os.path.join(DEPS, "vapoursynth"), os.path.join(DEPS, "python", "lib"),
                                 os.path.join(DEPS, "lib")]),
})

s = json.loads(subprocess.run([FP, "-v", "error", "-select_streams", "v:0", "-show_streams", "-of", "json", CLIP],
                              capture_output=True, text=True).stdout)["streams"][0]


def tag(k):
    v = (s.get(k) or "").strip()
    return None if v in ("", "unknown", "N/A") else v  # the app's colorTag


num, den = map(int, s["avg_frame_rate"].split("/"))
fps = num / den
frames = int(s.get("nb_frames") or round(float(s["duration"]) * fps))
print(f"clip: {s['codec_tag_string']} {s['width']}x{s['height']} {s['pix_fmt']} {s.get('field_order')} "
      f"{s['avg_frame_rate']} tb {s['time_base']} frames {frames}; csp={tag('color_space')} "
      f"prim={tag('color_primaries')} trc={tag('color_transfer')} range={tag('color_range')}")


def job(**extra):
    j = {
        "id": str(uuid.uuid4()), "inputPath": CLIP, "outputPath": os.path.join(OUT, "unused.mkv"),
        "qtgmcParameters": {"enabled": False},
        "processingPipeline": {"deinterlace": {"enabled": False}},
        "encodingSettings": {"codec": "ffv1", "container": "mkv", "audioMode": "none"},
        "detectedFieldOrder": "bff" if s.get("field_order") in ("bt", "bb") else "tff",
        "totalFrames": frames, "inputFrameRate": fps, "inputWidth": s["width"], "inputHeight": s["height"],
        "inputPixelFormat": s["pix_fmt"],
        "inputColorMatrix": tag("color_space"), "inputColorPrimaries": tag("color_primaries"),
        "inputColorTransfer": tag("color_transfer"), "inputColorRange": tag("color_range"),
    }
    j.update(extra)
    path = os.path.join(OUT, j["id"] + ".json")
    json.dump(j, open(path, "w"))
    return path


def run(label, args, stdout_file=None):
    t = time.time()
    r = subprocess.run([WORKER, *args], env=env, capture_output=True,
                       cwd=os.path.dirname(WORKER))
    dt = time.time() - t
    out = r.stdout
    if stdout_file:
        open(stdout_file, "wb").write(out)
    return r.returncode, out.decode(errors="replace"), r.stderr.decode(errors="replace"), dt


for flag in ["--detect-crop", "--detect-native", "--detect-noise-halo"]:
    code, out, err, dt = run(flag, [flag, "--config", job()])
    lines = [l for l in out.splitlines() if l.strip().startswith("{")]
    rep = json.loads(lines[-1]) if lines else {}
    if rep.get("error") or code:
        print(f"{flag:20} FAILED ({dt:.1f} s): {rep.get('error') or err[-300:]}")
        continue
    if flag == "--detect-crop":
        summary = f"crop {rep.get('crop')} usable {rep.get('usableFrames')}/{len(rep.get('frames', []))}"
    elif flag == "--detect-native":
        summary = f"found {rep.get('found')} height {rep.get('height')} kernel {rep.get('kernel')} dip {rep.get('dip')}"
    else:
        summary = ", ".join(f"{k} {v}" for k, v in rep.items() if k in ("noise", "noiseHigh", "halo", "haloHigh", "usablePairs"))
    print(f"{flag:20} OK ({dt:.1f} s): {summary}")

png = os.path.join(OUT, "preview_300.png")
code, out, err, dt = run("preview", ["--config", job(), "--preview", "--frame", "300"], stdout_file=png)
print(f"{'preview frame 300':20} {'OK' if code == 0 and os.path.getsize(png) > 0 else 'FAILED'} ({dt:.1f} s)"
      + ("" if code == 0 else ": " + err[-300:]))

enc = os.path.join(OUT, "trimmed_100_129.mkv")
code, out, err, dt = run("encode", ["--config", job(outputPath=enc, startFrame=100, endFrame=129, totalFrames=30)])  # totalFrames is the trimmed count, as the app sends
ok = code == 0 and os.path.exists(enc)
n = subprocess.run([FP, "-v", "error", "-count_frames", "-select_streams", "v:0", "-show_entries",
                    "stream=nb_read_frames", "-of", "csv=p=0", enc], capture_output=True, text=True).stdout.strip() if ok else "-"
print(f"{'trimmed encode':20} {'OK' if ok else 'FAILED'} ({dt:.1f} s), {n} frames"
      + ("" if ok else ": " + (out + err)[-400:]))
