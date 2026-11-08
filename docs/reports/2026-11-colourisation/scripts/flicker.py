#!/usr/bin/env python3
"""Colour flicker and colour lag, from the planes colorize_run.py --save-uv
writes (<tag>_y.npy, <tag>_u.npy, <tag>_v.npy: (frames, h, w) each, 8-bit
4:2:0 here). Adapted from the face report's metric
(docs/reports/2026-11-face-restoration/scripts/flicker.py) to chroma: the
luma is the source's, bit-exact, so all that can flicker is the colour.

Per variant, in 8-bit chroma levels, over 8x8-pixel blocks of the chroma
planes (16x16 of the picture):

- staticFlicker: mean |C[t] - (C[t-1] + C[t+1]) / 2| (U and V averaged) over
  blocks whose luma is still — mean luma moves by under STILL levels from
  t-1 to t and from t to t+1. There the picture has not changed, so any
  change of colour is the model's, i.e. flicker. The source's own value is 0.
- staticChange: mean |C[t] - C[t-1]| over the same still blocks.
- motionLag: over blocks whose luma MOVED by at least MOVING levels, the
  mean |C - C_ref| against the per-frame variant of the same model (radius
  0) — how far smoothing pulled moving colour away from what the model saw
  in that frame (ghosting or lag would raise it; 0 by definition for the
  reference itself).
- chroma: mean |C - 128|, how much colour there is at all (a variant that
  flickered less only by fading toward grey would show it here).

What the metric can't tell you: whether the colour is right (there is no
ground truth for a black-and-white film); it is one clip; and blocks that
are "still" by mean luma can still hold small motion.

    python flicker.py <dir> <ref tag for motionLag per model: model=tag ...> -- <tags...>
"""

import json
import os
import sys

import numpy as np

BLOCK = 8
STILL = 1.0
MOVING = 4.0


def blocks(a):
    """(frames, h, w) -> (frames, h/B, w/B) block means (edges cropped)."""
    f, h, w = a.shape
    h, w = h // BLOCK * BLOCK, w // BLOCK * BLOCK
    return a[:, :h, :w].reshape(f, h // BLOCK, BLOCK, w // BLOCK, BLOCK).mean((2, 4))


def luma_blocks(y):
    """Luma at chroma resolution (2x2 means), in blocks."""
    f, h, w = y.shape
    y = y[:, : h // 2 * 2, : w // 2 * 2].astype(np.float64)
    y = y.reshape(f, h // 2, 2, w // 2, 2).mean((2, 4))
    return blocks(y)


def load(d, tag):
    return [np.load(os.path.join(d, f"{tag}_{p}.npy")).astype(np.float64) for p in "yuv"]


def metrics(d, tag, ref=None):
    y, u, v = load(d, tag)
    ly = luma_blocks(y)
    cu, cv = blocks(u), blocks(v)
    dy_prev = np.abs(ly[1:-1] - ly[:-2])
    dy_next = np.abs(ly[2:] - ly[1:-1])
    still = (dy_prev < STILL) & (dy_next < STILL)
    flick = sum(np.abs(c[1:-1] - (c[:-2] + c[2:]) / 2) for c in (cu, cv)) / 2
    change = sum(np.abs(c[1:-1] - c[:-2]) for c in (cu, cv)) / 2
    out = {
        "staticFlicker": round(float(flick[still].mean()), 3),
        "staticChange": round(float(change[still].mean()), 3),
        "stillShare": round(float(still.mean()), 3),
        "chroma": round(float((np.abs(u - 128).mean() + np.abs(v - 128).mean()) / 2), 3),
    }
    if ref is not None:
        _, ru, rv = load(d, ref)
        moving = np.abs(ly[1:] - ly[:-1]) >= MOVING
        lag = (np.abs(cu - blocks(ru)) + np.abs(cv - blocks(rv)))[1:] / 2
        out["motionLag"] = round(float(lag[moving].mean()), 3)
        out["movingShare"] = round(float(moving.mean()), 3)
    return out


def main():
    d = sys.argv[1]
    sep = sys.argv.index("--")
    refs = dict(a.split("=", 1) for a in sys.argv[2:sep])
    rows = {}
    for tag in sys.argv[sep + 1:]:
        model = tag.split("_")[0]
        rows[tag] = metrics(d, tag, refs.get(model))
    print(json.dumps({"block": BLOCK, "still": STILL, "moving": MOVING, "rows": rows}, indent=2))


if __name__ == "__main__":
    main()
