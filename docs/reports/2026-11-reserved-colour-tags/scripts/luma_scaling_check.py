#!/usr/bin/env python3
"""Addendum (2026-11-14): Descale Detect's luma, gray16le vs the source's Y plane.

Usage: python3 -I luma_scaling_check.py <ffmpeg> <ffprobe> <workdir> [<worker> <deps dir>]

1. How FFmpeg's decode to gray16le relates to the Y plane, untagged and
   BT.709-tagged, and that the worker's scaling (`native_res::luma_gray16`,
   restated below) reproduces the untagged decode.
2. With a worker: `--detect-native` on a 10-bit Catmull-Rom 720p -> 1080p
   master, untagged and BT.709-tagged (the same samples).

Before the fix this worker step was not scripted; the before numbers in the
report come from integration_descale_test.dart's twin pair (its 8-bit master
re-encoded at 10-bit), run against the unfixed worker.

Fixtures are built in <workdir> from ffmpeg's testsrc2; no repo files.
"""
import json, os, struct, subprocess, sys, uuid

FF, FP, WD = sys.argv[1:4]
WORKER, DEPS = (sys.argv[4], sys.argv[5]) if len(sys.argv) > 5 else (None, None)
os.makedirs(WD, exist_ok=True)
W, H = 320, 240
TAG709 = "setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709"


def w(name):
    return os.path.join(WD, name)


def ff(*args):
    subprocess.run([FF, "-v", "error", "-y", *args], check=True)


def decode(path, fmt, vf=None):
    args = [FF, "-v", "error", "-i", path, "-frames:v", "1"]
    if vf:
        args += ["-vf", vf]
    return subprocess.run(args + ["-f", "rawvideo", "-pix_fmt", fmt, "-"],
                          capture_output=True, check=True).stdout


def u16(b, n):
    return struct.unpack(f"<{n}H", b[:2 * n])


def luma(path, fmt, depth):
    b = decode(path, fmt)
    n = W * H
    return list(b[:n]) if depth == 8 else list(u16(b, n))


def luma_gray16(y, depth, full):
    # The worker's scaling, restated (worker/src/native_res.rs).
    unit = 1 << max(depth - 8, 0)
    black, rng = (0, (1 << depth) - 1) if full else (16 * unit, 219 * unit)
    return [min(65535, max(0, round((v - black) * 65535 / rng))) for v in y]


print("== FFmpeg:", subprocess.run([FF, "-version"], capture_output=True, text=True).stdout.splitlines()[0])
print("\n== 1. gray16le vs the Y plane (320x240 testsrc2, FFV1), max |diff| in 16-bit codes")
cases = [("yuv420p", 8, False, []), ("yuv420p10le", 10, False, []),
         ("yuv420p10le", 10, True, ["-color_range", "pc"]), ("yuvj420p", 8, True, [])]
for fmt, depth, full, extra in cases:
    src = w(f"{fmt}{'_pc' if extra else ''}.mkv")
    ff("-f", "lavfi", "-i", f"testsrc2=s={W}x{H}:d=0.04", "-pix_fmt", fmt, *extra, "-c:v", "ffv1", src)
    y = luma(src, fmt, depth)
    g = u16(decode(src, "gray16le"), W * H)
    mine = luma_gray16(y, depth, full)
    d = max(abs(a - b) for a, b in zip(mine, g))
    label = f"{fmt}{' pc' if extra else ''}"
    print(f"  {label:16} untagged gray16le vs luma_gray16: {d} ({d / 257:.2f} levels)")
    if fmt == "yuv420p10le" and not extra:
        g709 = u16(decode(src, "gray16le", TAG709), W * H)
        diffs = [abs(a - b) for a, b in zip(g, g709)]
        print(f"  {label:16} gray16le, bt709-tagged vs untagged: max {max(diffs)} "
              f"({max(diffs) / 257:.1f} levels), mean {sum(diffs) / len(diffs) / 257:.1f} levels")
        same = decode(src, fmt) == decode(src, fmt, TAG709)
        print(f"  {label:16} {fmt} (the pipe format), bt709-tagged vs untagged: "
              f"{'identical' if same else 'DIFFERS'}")

if WORKER:
    print("\n== 2. --detect-native on a 10-bit 720p -> 1080p Catmull-Rom master")
    ff("-f", "lavfi", "-i", "testsrc2=s=1280x720:r=30000/1001:d=0.4",
       "-vf", "scale=1920:1080:flags=bicubic:param0=0:param1=0.5,format=yuv420p10le",
       "-c:v", "ffv1", w("catrom10.mkv"))
    ff("-i", w("catrom10.mkv"), "-vf", TAG709, "-colorspace", "bt709", "-color_primaries", "bt709",
       "-color_trc", "bt709", "-c:v", "ffv1", w("catrom10_709.mkv"))
    env = dict(os.environ)  # macOS/Linux, as real_clip_worker.py (WorkerHarness.workerEnv)
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
    for name, tag in [("catrom10.mkv", None), ("catrom10_709.mkv", "bt709")]:
        job = {"id": str(uuid.uuid4()), "inputPath": w(name), "outputPath": w("out.mkv"),
               "qtgmcParameters": {}, "encodingSettings": {}, "inputWidth": 1920, "inputHeight": 1080,
               "inputPixelFormat": "yuv420p10le", "inputFrameRate": 29.97, "totalFrames": 12,
               "inputColorMatrix": tag, "inputColorPrimaries": tag, "inputColorTransfer": tag}
        cfg = w("job.json")
        json.dump(job, open(cfg, "w"))
        out = subprocess.run([WORKER, "--detect-native", "--config", cfg], capture_output=True,
                             text=True, env=env, cwd=os.path.dirname(WORKER)).stdout
        r = json.loads([l for l in out.splitlines() if l.strip().startswith("{")][-1])
        print(f"  {name:17} found {r['found']}, {r['height']}p {r['kernel']} "
              f"b={r['bicubicB']} c={r['bicubicC']}, dip {r['dip']:.6f}")
