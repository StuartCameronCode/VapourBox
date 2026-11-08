#!/usr/bin/env python3
"""Flicker in the face region, from the luma .npy files face_run.py --save-y
writes (one (frames, h, w) array per variant).

Three numbers per variant, all over a fixed face rectangle (the median of the
detected boxes on the clean reference, shrunk to the face's middle 60%, so
hair and background never enter it), in 8-bit luma levels:

- tdiff:  mean |Y[t] - Y[t-1]|              (all temporal change, incl. motion)
- flick:  mean |Y[t] - (Y[t-1] + Y[t+1])/2|  (frame-to-frame change that is not
          explained by smooth motion: noise, texture that comes and goes,
          a face that jumps)
- errVsClean: mean |Y - clean| (distance from the undegraded source)

The clean reference (the undegraded source, same crop and scale) gives the
floor: what the true motion of the face costs. What the metric can't tell
you: it is one clip of one talking head; it doesn't separate "restorer
hallucinated new texture" from "restorer followed real motion" beyond the
second difference; lower is not better past the clean reference's value
(a frozen face would score 0).

    python flicker.py <dir with *_y.npy> <clean_y.npy> [x0 y0 x1 y1]
"""

import json
import os
import sys

import numpy as np


def metrics(y, rect, clean=None):
    x0, y0, x1, y1 = rect
    r = y[:, y0:y1, x0:x1].astype(np.float64)
    tdiff = np.abs(np.diff(r, axis=0)).mean()
    flick = np.abs(r[1:-1] - (r[:-2] + r[2:]) / 2).mean()
    out = {"tdiff": round(float(tdiff), 3), "flick": round(float(flick), 3)}
    if clean is not None:
        # Mean distance from the undegraded source: not a quality score (a
        # restorer invents plausible detail, which a pixel metric counts as
        # error), but a blend that ghosted or smeared motion would raise it.
        c = clean[: len(y), y0:y1, x0:x1].astype(np.float64)
        out["errVsClean"] = round(float(np.abs(r[: len(c)] - c).mean()), 3)
    return out


def main():
    d, clean_path = sys.argv[1], sys.argv[2]
    rect = [int(v) for v in sys.argv[3:7]] if len(sys.argv) >= 7 else None
    clean = np.load(clean_path)
    if rect is None:
        raise SystemExit("pass the face rectangle x0 y0 x1 y1")
    rows = {"clean reference": metrics(clean, rect)}
    for name in sorted(os.listdir(d)):
        if name.endswith("_y.npy"):
            y = np.load(os.path.join(d, name))
            n = min(len(y), len(clean))
            rows[name[:-6]] = metrics(y[:n], rect, clean)
    print(json.dumps({"rect": rect, "rows": rows}, indent=2))


if __name__ == "__main__":
    main()
