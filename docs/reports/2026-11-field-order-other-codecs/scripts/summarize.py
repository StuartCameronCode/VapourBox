#!/usr/bin/env python3
"""Summarise quality.sh's CSV: per fixture, interlaced (MBAFF) minus progressive
at equal bitrate (the 2-pass rows), and the Bjøntegaard rate difference over
the CRF rows (bitrate change for the same field PSNR; negative = smaller).

    python3 summarize.py quality.csv

BD-rate is computed the usual way, but with piecewise-linear interpolation of
log(rate) against PSNR rather than a cubic fit (four points per curve; no
NumPy needed), over the PSNR range both curves cover.
"""
import csv
import math
import sys
from collections import defaultdict


def interp(points, x):
    for (x0, y0), (x1, y1) in zip(points, points[1:]):
        if x0 <= x <= x1:
            return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
    raise ValueError(x)


def bd_rate(ref, test):
    """ref/test: [(kbps, psnr)]. Mean % rate change of test vs ref."""
    r = sorted((p, math.log(k)) for k, p in ref)
    t = sorted((p, math.log(k)) for k, p in test)
    lo, hi = max(r[0][0], t[0][0]), min(r[-1][0], t[-1][0])
    steps = 200
    diff = 0.0
    for i in range(steps + 1):
        x = lo + (hi - lo) * i / steps
        diff += interp(t, x) - interp(r, x)
    return (math.exp(diff / (steps + 1)) - 1) * 100


rows = list(csv.DictReader(open(sys.argv[1])))
by = defaultdict(dict)
for row in rows:
    by[(row["fixture"], row["rate_control"])][(row["mode"], row["setting"])] = row

for fx in sorted({r["fixture"] for r in rows}, key=["vhs", "dvbt", "bff"].index):
    print(f"== {fx}")
    two = by[(fx, "2pass")]
    for k in sorted({s for _, s in two}, key=int):
        p, i = two[("progressive", k)], two[("interlaced", k)]
        print(f"  2-pass {k:>5} kbit/s: PSNR-Y {float(p['psnr_y']):.2f} -> {float(i['psnr_y']):.2f} "
              f"({float(i['psnr_y']) - float(p['psnr_y']):+.2f} dB), "
              f"SSIM {float(p['ssim']):.4f} -> {float(i['ssim']):.4f}, "
              f"time {p['seconds']} -> {i['seconds']} s")
    crf = by[(fx, "crf")]
    ref = [(float(v["kbps"]), float(v["psnr_y"])) for (m, _), v in crf.items() if m == "progressive"]
    test = [(float(v["kbps"]), float(v["psnr_y"])) for (m, _), v in crf.items() if m == "interlaced"]
    print(f"  BD-rate over CRF 14-26 (field PSNR-Y): {bd_rate(ref, test):+.1f} %")
