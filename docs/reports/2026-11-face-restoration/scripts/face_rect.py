#!/usr/bin/env python3
"""The fixed face rectangle flicker.py measures in: RetinaFace (the add-on's
ONNX model, through face_restore.detect) on every frame of the clean
reference, the median box, shrunk to its middle 60% so it holds only face.
Also prints per-frame detection counts and the landmark jitter (frame-to-frame
movement of the five points, pixels) on the clip given, for the detector
comparison.

    VAPOURBOX_ADDON_STAGING=<dir with the .onnx files> \\
        python face_rect.py <clip> [r50|mnet]       (ffmpeg on PATH; conversion venv)
"""
import json
import os
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "..", "worker", "templates"))
import face_restore as fr  # noqa: E402
import onnxruntime as ort  # noqa: E402


def main():
    clip = sys.argv[1]
    kind = sys.argv[2] if len(sys.argv) > 2 else "r50"
    staging = os.environ["VAPOURBOX_ADDON_STAGING"]
    sess = ort.InferenceSession(os.path.join(staging, f"face-restoration-retinaface-{kind}.onnx"),
                                providers=["CPUExecutionProvider"])
    info = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                                               "stream=width,height", "-of", "json", clip]))["streams"][0]
    w, h = info["width"], info["height"]
    # As face_restore does: scaled (bicubic) to fit the detector's 640 square.
    scale = min(1.0, fr.DET_SIZE / max(w, h))
    w, h = round(w * scale), round(h * scale)
    raw = subprocess.check_output(["ffmpeg", "-v", "error", "-i", clip, "-vf", f"scale={w}:{h}:flags=bicubic",
                                   "-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
    frames = np.frombuffer(raw, np.uint8).reshape(-1, h, w, 3)
    boxes, marks, scores, counts = [], [], [], []
    for f in frames:
        s, b, m = fr.detect(sess, f.transpose(2, 0, 1).astype(np.float32) / 255.0, (scale, scale), 0.5)
        counts.append(int((s >= 0.8).sum()))
        if len(s):
            boxes.append(b[0])
            marks.append(m[0])
            scores.append(float(s[0]))
    med = np.median(np.array(boxes), 0)
    cx, cy = (med[0] + med[2]) / 2, (med[1] + med[3]) / 2
    hw, hh = (med[2] - med[0]) * 0.3, (med[3] - med[1]) * 0.3
    rect = [int(cx - hw), int(cy - hh), int(cx + hw), int(cy + hh)]
    marks = np.array(marks)
    jitter = np.abs(marks[1:-1] - (marks[:-2] + marks[2:]) / 2).mean() if len(marks) > 2 else None
    print(json.dumps({"detector": kind, "frames": len(frames), "framesWithFace>=0.8": int(sum(c > 0 for c in counts)),
                      "minScore": min(scores), "meanScore": float(np.mean(scores)),
                      "landmarkJitterPx": None if jitter is None else round(float(jitter), 3),
                      "medianBox": [round(float(v), 1) for v in med], "rect": rect}))


if __name__ == "__main__":
    main()
