#!/usr/bin/env python3
"""Check worker/templates/face_restore.py's NumPy pipeline against the
reference it reimplements without OpenCV: facexlib's PyTorch RetinaFace
(detect_faces), cv2.estimateAffinePartial2D + cv2.warpAffine (alignment), and
facexlib's paste-back (BiSeNet mask, two Gaussian blurs, cv2.warpAffine back).

Run in the conversion venv (torch, opencv-python-headless, onnxruntime) after
Scripts/models/make_face_restoration.py, with:

    FACE_MODELS_WORK=<work dir used for the conversion>   (facexlib source + checkpoints)
    VAPOURBOX_ADDON_STAGING=<dir holding the converted .onnx files>
    python pipeline_parity.py <clip> [frame ...]

Prints JSON: per frame, detection differences (pixels), alignment matrix
difference, aligned-crop difference, and the final frame difference (8-bit
levels) between the two paste-backs given the same restored face.
"""

import json
import os
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
sys.path.insert(0, os.path.join(REPO, "worker", "templates"))
sys.path.insert(0, os.path.join(REPO, "Scripts", "models"))

import cv2  # noqa: E402
import onnxruntime as ort  # noqa: E402
import torch  # noqa: E402

import face_models_common as fm  # noqa: E402
import face_restore as fr  # noqa: E402
import make_face_restoration as mfr  # noqa: E402


def frames_rgb(path, wanted):
    probe = subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                                     "stream=width,height", "-of", "csv=p=0", path]).decode().split(",")
    w, h = int(probe[0]), int(probe[1])
    raw = subprocess.check_output(["ffmpeg", "-v", "error", "-i", path, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
    allf = np.frombuffer(raw, np.uint8).reshape(-1, h, w, 3)
    return {n: allf[n] for n in wanted}


def main():
    clip = sys.argv[1]
    wanted = [int(x) for x in sys.argv[2:]] or [0, 40, 80, 120]
    staging = fm.STAGING
    det_pt = mfr.detector("r50")
    det_onnx = ort.InferenceSession(os.path.join(staging, "face-restoration-retinaface-r50.onnx"),
                                    providers=["CPUExecutionProvider"])
    parse_onnx = ort.InferenceSession(os.path.join(staging, "face-restoration-bisenet.onnx"),
                                      providers=["CPUExecutionProvider"])
    restore_onnx = ort.InferenceSession(os.path.join(staging, "face-restoration-restoreformerpp.onnx"),
                                        providers=["CPUExecutionProvider"])
    out = []
    for n, rgb8 in frames_rgb(clip, wanted).items():
        h, w, _ = rgb8.shape
        assert max(h, w) <= fr.DET_SIZE, "use a clip that needs no detection resize (<= 640)"
        bgr = rgb8[..., ::-1].copy()
        with torch.no_grad():
            ref = det_pt.detect_faces(bgr, conf_threshold=0.8)  # x1 y1 x2 y2 score, 5 landmarks
        rgb = rgb8.transpose(2, 0, 1).astype(np.float32) / 255.0
        scores, boxes, marks = fr.detect(det_onnx, rgb, (1.0, 1.0), 0.8)
        row = {"frame": n, "faces": [len(ref), len(scores)]}
        if len(ref) and len(scores):
            # face_restore maps detection pixels with the half-pixel convention;
            # at scale 1 that is the identity, so these compare directly.
            row["boxMaxDiff"] = float(np.abs(ref[0, :4] - boxes[0]).max())
            row["landmarkMaxDiff"] = float(np.abs(ref[0, 5:].reshape(5, 2) - marks[0]).max())
            row["scoreDiff"] = float(abs(ref[0, 4] - scores[0]))
            lm = marks[0]
            m_cv = cv2.estimateAffinePartial2D(lm, fr.FFHQ_TEMPLATE, method=cv2.LMEDS)[0]
            m_np = fr.similarity(lm, fr.FFHQ_TEMPLATE)
            row["affineMaxDiff"] = float(np.abs(m_cv - m_np).max())
            crop_cv = cv2.warpAffine(rgb.transpose(1, 2, 0), m_np, (512, 512), borderMode=cv2.BORDER_CONSTANT,
                                     borderValue=tuple(float(v) for v in fr.BORDER_RGB)).transpose(2, 0, 1)
            crop_np = fr.align(rgb, m_np)
            row["alignedCropMaxDiff8bit"] = float(np.abs(crop_cv - crop_np).max() * 255)
            restored = np.clip((restore_onnx.run(None, {"input": (crop_np * 2 - 1)[None]})[0][0] + 1) / 2, 0, 1)
            # facexlib's paste-back (use_parse branch), with BiSeNet and the
            # face classes face_restore uses.
            x = ((restored - fr.PARSE_MEAN) / fr.PARSE_STD)[None].astype(np.float32)
            labels = parse_onnx.run(None, {"input": x})[0][0].argmax(0)
            mask = np.isin(labels, fr.FACE_CLASSES).astype(np.float64) * 255
            mask = cv2.GaussianBlur(mask, (101, 101), 11)
            mask = cv2.GaussianBlur(mask, (101, 101), 11)
            mask[:10], mask[-10:], mask[:, :10], mask[:, -10:] = 0, 0, 0, 0
            mask = mask / 255.0
            inv = cv2.invertAffineTransform(m_np)
            inv_face = cv2.warpAffine(restored.transpose(1, 2, 0), inv, (w, h))
            inv_mask = cv2.warpAffine(mask, inv, (w, h), flags=3)[..., None]
            ref_frame = inv_mask * inv_face + (1 - inv_mask) * rgb.transpose(1, 2, 0)
            # face_restore's: paste the face where its mask reaches, blend once.
            o = rgb.copy()
            a = np.zeros((h, w), np.float32)
            fr.paste(rgb, o, a, restored, fr.face_mask(parse_onnx.run(None, {"input": x})[0]), m_np)
            ours = (a[None] * o + (1 - a[None]) * rgb).transpose(1, 2, 0)
            d = np.abs(ref_frame - ours) * 255
            row["frameMaxDiff8bit"] = float(d.max())
            row["frameMeanDiff8bitInFace"] = float(d[a > 0].mean())
            ref_reach = inv_mask[..., 0] > 1 / 1024
            row["maskReachPixels"] = [int(ref_reach.sum()), int((a > 0).sum())]
        out.append(row)
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
