#!/usr/bin/env python3
"""Run worker/templates/face_restore.py on a clip inside the deps bundle's
Python, time it, and save what the flicker and image comparisons need.

Run with the deps bundle's Python and VapourSynth importable (as the vspipe
wrapper sets them up), the repo's worker/templates and the ai-runtime add-on's
site-packages on PYTHONPATH, ffmpeg/ffprobe on PATH, and
VAPOURBOX_ADDON_STAGING pointing at the converted .onnx files (run.sh does
all of this). VAPOURBOX_AI_FORCE_CPU=1 runs every model on the CPU.

    face_run.py --clip FILE [--model restoreformer|gfpgan|codeformer]
                [--radius R] [--no-blend] [--strength S] [--fidelity W]
                [--frames A:B] [--png N ...] [--save-y] [--out DIR] [--tag NAME]
                [--det r50|mnet]

Prints one JSON line: frames, seconds, fps, the provider each model ran on,
and any CPU fallback.
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
FILES = {
    "restoreformer": "face-restoration-restoreformerpp.onnx",
    "gfpgan": "face-gfpgan-v1.4.onnx",
    "codeformer": "face-codeformer-v0.1.0.onnx",
}


def load(path, frames=None):
    """A clip of `path` decoded by ffmpeg to 8-bit 4:2:0 (the fixtures' format)."""
    info = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                                               "stream=width,height", "-of", "json", path]))["streams"][0]
    w, h = info["width"], info["height"]
    raw = subprocess.check_output(["ffmpeg", "-v", "error", "-i", path, "-f", "rawvideo", "-pix_fmt", "yuv420p", "-"])
    per = w * h * 3 // 2
    data = np.frombuffer(raw, np.uint8)
    n = len(data) // per
    a, b = frames if frames else (0, n)
    blank = core.std.BlankClip(width=w, height=h, format=vs.YUV420P8, length=b - a, fpsnum=30000, fpsden=1001)
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
    rgb = core.resize.Bicubic(clip[n], format=vs.RGB24, matrix_in_s="470bg")
    f = rgb.get_frame(0)
    arr = np.ascontiguousarray(np.stack([np.asarray(f[p]) for p in range(3)], -1))
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s",
                    f"{clip.width}x{clip.height}", "-i", "-", "-frames:v", "1", path],
                   input=arr.tobytes(), check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--clip", required=True)
    ap.add_argument("--model", default="restoreformer", choices=sorted(FILES))
    ap.add_argument("--radius", type=int, default=1)
    ap.add_argument("--no-blend", action="store_true")
    ap.add_argument("--strength", type=float, default=1.0)
    ap.add_argument("--fidelity", type=float, default=0.7)
    ap.add_argument("--threshold", type=float, default=0.8)
    ap.add_argument("--frames", default=None)
    ap.add_argument("--png", type=int, action="append", default=[])
    ap.add_argument("--save-y", action="store_true")
    ap.add_argument("--out", default=".")
    ap.add_argument("--tag", default="run")
    ap.add_argument("--det", default="r50", choices=["r50", "mnet"])
    args = ap.parse_args()
    import face_restore

    frames = tuple(int(x) for x in args.frames.split(":")) if args.frames else None
    src = load(args.clip, frames)
    t0 = time.perf_counter()
    # Mirrors the generated script's call (worker/templates/*_template.vpy).
    out = face_restore.restore_faces(
        src,
        detector=os.path.join(STAGING, f"face-restoration-retinaface-{args.det}.onnx"),
        parser=os.path.join(STAGING, "face-restoration-bisenet.onnx"),
        restorer=os.path.join(STAGING, FILES[args.model]),
        model=args.model, strength=args.strength, fidelity=args.fidelity, threshold=args.threshold,
        temporal_radius=args.radius, temporal_blend=not args.no_blend,
        matrix="470bg", color_range="limited")
    setup = time.perf_counter() - t0
    os.makedirs(args.out, exist_ok=True)
    ys = []
    t0 = time.perf_counter()
    for f in out.frames(close=True):
        if args.save_y:
            ys.append(np.asarray(f[0]).copy())
    dt = time.perf_counter() - t0
    for n in args.png:
        save_png(out, n, os.path.join(args.out, f"{args.tag}_{n}.png"))
    if args.save_y:
        np.save(os.path.join(args.out, f"{args.tag}_y.npy"), np.stack(ys))
    runners = face_restore.last_restorer
    print(json.dumps({
        "tag": args.tag, "model": args.model, "radius": args.radius, "blend": not args.no_blend,
        "size": f"{src.width}x{src.height}", "frames": out.num_frames,
        "setupSeconds": round(setup, 2), "seconds": round(dt, 2), "fps": round(out.num_frames / dt, 3),
        "providers": {k: r.provider for k, r in runners.items()},
        "fallback": {k: r.fallback for k, r in runners.items() if r.fallback},
    }))


if __name__ == "__main__":
    main()
