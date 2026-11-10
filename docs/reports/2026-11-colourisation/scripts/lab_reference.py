#!/usr/bin/env python3
"""The reference half of the CIELAB check: OpenCV's own recombination, as
DDColor's ColorizationPipeline does it, on synthetic planes.

A grey picture Y (a value in [0, 1] repeated in R, G and B) gives its L
(cv2.COLOR_RGB2Lab on float32); L with predicted a and b goes back to RGB
(cv2.COLOR_LAB2RGB). lab_parity.py feeds the same Y, a and b to
colorize.lab_stages (std.Expr) and compares.

Run in the conversion venv (it has opencv-python-headless):

    python lab_reference.py <out.npz>
"""
import sys

import cv2
import numpy as np


def main():
    rng = np.random.default_rng(0)
    h, w = 256, 256
    y = np.concatenate([np.linspace(0, 1, h * w // 2), rng.uniform(0, 1, h * w // 2)]).reshape(h, w)
    y = y.astype(np.float32)
    a = rng.uniform(-110, 110, (h, w)).astype(np.float32)
    b = rng.uniform(-110, 110, (h, w)).astype(np.float32)
    grey = np.repeat(y[..., None], 3, axis=2)
    lightness = cv2.cvtColor(grey, cv2.COLOR_RGB2Lab)[:, :, :1]
    lab = np.concatenate([lightness, a[..., None], b[..., None]], axis=2)
    rgb = cv2.cvtColor(lab, cv2.COLOR_LAB2RGB)
    np.savez(sys.argv[1], y=y, a=a, b=b, rgb=rgb.astype(np.float32), cv2=cv2.__version__)
    print("cv2", cv2.__version__, "rgb range", float(rgb.min()), float(rgb.max()))


if __name__ == "__main__":
    main()
