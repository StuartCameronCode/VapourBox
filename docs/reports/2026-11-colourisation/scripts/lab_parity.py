#!/usr/bin/env python3
"""Check colorize.lab_stages (the std.Expr chain that recombines DDColor's
a and b with the frame's lightness) on the planes lab_reference.py wrote:

- against OpenCV (cv2.COLOR_LAB2RGB on float32, what DDColor's own pipeline
  calls), and
- against the same conversion written out in float64 NumPy with the exact
  sRGB curve (OpenCV's float path tabulates its gamma, which is where the two
  part company, near black).

Run inside the deps bundle's Python (run.sh):

    ./run.sh lab_parity.py <ref.npz>

Prints max and mean |difference| per channel in 8-bit levels.
"""
import json
import sys

import numpy as np
import vapoursynth as vs

import colorize

core = vs.core


def plane(arr):
    h, w = arr.shape
    blank = core.std.BlankClip(width=w, height=h, format=vs.GRAYS, length=1)

    def fill(n, f):
        out = f.copy()
        np.copyto(np.asarray(out[0]), arr)
        return out

    return core.std.ModifyFrame(blank, blank, fill)


def exact(y, a, b):
    """CIELAB (L of the grey value y, a, b) -> sRGB, float64, exact curves,
    OpenCV's constants (colorize.py's XN, ZN, XYZ_TO_RGB)."""
    ylin = np.where(y <= 0.04045, y / 12.92, ((y + 0.055) / 1.055) ** 2.4)
    fy = np.where(ylin > colorize.LAB_T, np.cbrt(ylin), colorize.LAB_K * ylin + 16 / 116)

    def finv(f):
        return np.where(f > colorize.LAB_F, f ** 3, (f - 16 / 116) / colorize.LAB_K)

    x = colorize.XN * finv(fy + a / 500)
    z = colorize.ZN * finv(fy - b / 200)
    lin = np.stack([r[0] * x + r[1] * ylin + r[2] * z for r in colorize.XYZ_TO_RGB], -1).clip(0, 1)
    return np.where(lin <= 0.0031308, 12.92 * lin, 1.055 * lin ** (1 / 2.4) - 0.055)


def stats(d):
    return {"maxLevels": [round(float(d[..., c].max()), 4) for c in range(3)],
            "meanLevels": [round(float(d[..., c].mean()), 5) for c in range(3)]}


def main():
    ref = np.load(sys.argv[1])
    rgb = colorize.lab_stages(core, plane(ref["y"]), plane(ref["a"]), plane(ref["b"]))
    f = rgb.get_frame(0)
    got = np.stack([np.asarray(f[p]) for p in range(3)], -1).astype(np.float64)
    y, a, b = (ref[k].astype(np.float64) for k in "yab")
    out = {"opencv": str(ref["cv2"]), "pixels": int(y.size),
           "exprVsOpenCV": stats(np.abs(got - ref["rgb"].astype(np.float64)) * 255),
           "exprVsExactFormula": stats(np.abs(got - exact(y, a, b)) * 255),
           "exactFormulaVsOpenCV": stats(np.abs(exact(y, a, b) - ref["rgb"].astype(np.float64)) * 255)}
    print(json.dumps(out))


if __name__ == "__main__":
    main()
