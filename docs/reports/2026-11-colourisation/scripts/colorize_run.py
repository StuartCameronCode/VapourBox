#!/usr/bin/env python3
"""Run worker/templates/colorize.py on a clip inside the deps bundle's Python,
time it, and save what the flicker and image comparisons need.

Run with the deps bundle's Python and VapourSynth importable, the repo's
worker/templates and the ai-runtime add-on's site-packages on PYTHONPATH,
ffmpeg/ffprobe on PATH and VAPOURBOX_ADDON_STAGING pointing at the converted
.onnx files (run.sh does all of this). VAPOURBOX_AI_FORCE_CPU=1 runs the
model on the CPU.

    colorize_run.py --clip FILE [--model ddcolor|deoldify] [--size N]
                    [--radius R] [--strength S] [--frames A:B] [--depth 8|10|16]
                    [--png N ...] [--save-uv] [--out DIR] [--tag NAME]
                    [--preview] [--field-based 1|2]

Prints one JSON line: frames, seconds, fps, provider, any CPU fallback, and
whether the output's Y plane equals the input's (it must).
"""
import argparse
import json
import os
import subprocess
import time

import numpy as np
import vapoursynth as vs

core = vs.core
STAGING = os.environ.get("VAPOURBOX_ADDON_STAGING", "")
FILES = {"ddcolor": "colorize-ddcolor-tiny.onnx", "deoldify": "colorize-deoldify-video.onnx"}


def load(path, frames=None):
    """A clip of `path` decoded by ffmpeg to 8-bit 4:2:0."""
    info = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                                               "stream=width,height", "-of", "json", path]))["streams"][0]
    w, h = info["width"], info["height"]
    raw = subprocess.check_output(["ffmpeg", "-v", "error", "-i", path, "-f", "rawvideo", "-pix_fmt", "yuv420p", "-"])
    per = w * h * 3 // 2
    data = np.frombuffer(raw, np.uint8)
    n = len(data) // per
    a, b = frames if frames else (0, n)
    blank = core.std.BlankClip(width=w, height=h, format=vs.YUV420P8, length=b - a, fpsnum=24, fpsden=1)
    sizes = [(h, w), (h // 2, w // 2), (h // 2, w // 2)]

    def fill(n, f):
        out = f.copy()
        off = (a + n) * per
        for p, (ph, pw) in enumerate(sizes):
            np.copyto(np.asarray(out[p]), data[off:off + ph * pw].reshape(ph, pw))
            off += ph * pw
        return out

    return core.std.ModifyFrame(blank, blank, fill)


def save_png(clip, n, path):
    rgb = core.resize.Bicubic(clip[n], format=vs.RGB24, matrix_in_s="470bg", dither_type="error_diffusion")
    f = rgb.get_frame(0)
    arr = np.ascontiguousarray(np.stack([np.asarray(f[p]) for p in range(3)], -1))
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s",
                    f"{clip.width}x{clip.height}", "-i", "-", "-frames:v", "1", path],
                   input=arr.tobytes(), check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--clip", required=True)
    ap.add_argument("--model", default="ddcolor", choices=sorted(FILES))
    ap.add_argument("--size", type=int, default=None)
    ap.add_argument("--radius", type=int, default=2)
    ap.add_argument("--strength", type=float, default=1.0)
    ap.add_argument("--frames", default=None)
    ap.add_argument("--depth", type=int, default=8)
    ap.add_argument("--png", type=int, action="append", default=[])
    ap.add_argument("--save-uv", action="store_true")
    ap.add_argument("--out", default=".")
    ap.add_argument("--tag", default="run")
    ap.add_argument("--preview", action="store_true")
    ap.add_argument("--motion-limit", type=float, default=None, help="8-bit levels")
    ap.add_argument("--field-based", type=int, default=None)
    args = ap.parse_args()
    import colorize

    size = args.size or (512 if args.model == "ddcolor" else 336)
    frames = tuple(int(x) for x in args.frames.split(":")) if args.frames else None
    src = load(args.clip, frames)
    if args.depth != 8:
        src = core.resize.Point(src, format=core.query_video_format(vs.YUV, vs.INTEGER, args.depth, 1, 1).id)
    if args.field_based is not None:
        # As the templates' SET_FIELD_BASED leaves a still-interlaced clip.
        src = core.std.SetFieldBased(src, args.field_based)
    t0 = time.perf_counter()
    # Mirrors the generated script's call (worker/templates/*_template.vpy).
    out = colorize.colorize(src, model_path=os.path.join(STAGING, FILES[args.model]), model=args.model,
                            render_size=size, strength=args.strength, temporal_radius=args.radius,
                            matrix="470bg", color_range="limited", preview=args.preview,
                            **({"motion_limit": args.motion_limit / 255.0} if args.motion_limit else {}))
    setup = time.perf_counter() - t0
    os.makedirs(args.out, exist_ok=True)
    ys, us, vs_, y_exact = [], [], [], True
    t0 = time.perf_counter()
    for i, (f, g) in enumerate(zip(out.frames(close=True), src.frames(close=True))):
        if not np.array_equal(np.asarray(f[0]), np.asarray(g[0])):
            y_exact = False
        if args.save_uv:
            ys.append(np.asarray(f[0]).copy())
            us.append(np.asarray(f[1]).copy())
            vs_.append(np.asarray(f[2]).copy())
    dt = time.perf_counter() - t0
    for n in args.png:
        save_png(out, n, os.path.join(args.out, f"{args.tag}_{n}.png"))
    if args.save_uv:
        np.save(os.path.join(args.out, f"{args.tag}_y.npy"), np.stack(ys))
        np.save(os.path.join(args.out, f"{args.tag}_u.npy"), np.stack(us))
        np.save(os.path.join(args.out, f"{args.tag}_v.npy"), np.stack(vs_))
    runner = colorize.last_runner
    print(json.dumps({
        "tag": args.tag, "model": args.model, "renderSize": size, "radius": args.radius,
        "strength": args.strength, "depth": args.depth, "motionLimit": args.motion_limit, "preview": args.preview,
        "size": f"{src.width}x{src.height}", "frames": out.num_frames,
        "setupSeconds": round(setup, 2), "seconds": round(dt, 2), "fps": round(out.num_frames / dt, 3),
        "provider": runner.provider, "fallback": runner.fallback, "lumaBitExact": y_exact,
    }), flush=True)


if __name__ == "__main__":
    main()
