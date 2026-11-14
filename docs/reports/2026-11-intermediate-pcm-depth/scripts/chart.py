"""Figure 1: per case, the level the restoration leaves in the pauses against
each variant's error, in dBFS. Reads $WORK/pcm_depth.json (pcm_depth_probe.py),
writes ../img/01-error-vs-floor.svg.

    WORK=/scratch python3 chart.py
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
rows = json.load(open(os.path.join(os.environ["WORK"], "pcm_depth.json")))["rows"]

LO, HI = -150.0, -10.0
L, R, T, ROW = 250, 24, 64, 26
W = 860
H = T + ROW * len(rows) + 56
SERIES = [  # key, label, colour, hollow
    ("gap_floor", "restored track in the pauses", "#77756f", False),
    ("s16_tpdf", "16-bit + TPDF dither: error", "#a35ec4", True),
    ("s16", "16-bit (before): error", "#d9822b", False),
    ("s24", "24-bit (now): error", "#3b7dd8", False),
]


def x(v):
    v = max(LO, min(HI, v))
    return L + (v - LO) / (HI - LO) * (W - L - R)


out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" '
       'font-family="-apple-system, BlinkMacSystemFont, Segoe UI, sans-serif" font-size="12">',
       f'<rect width="{W}" height="{H}" fill="#fcfcfb"/>']
for v in range(int(LO), int(HI) + 1, 10):
    out.append(f'<line x1="{x(v):.1f}" y1="{T - 6}" x2="{x(v):.1f}" y2="{H - 50}" stroke="#e4e3de"/>')
    out.append(f'<text x="{x(v):.1f}" y="{H - 36}" text-anchor="middle" fill="#52514e">{v}</text>')
out.append(f'<text x="{(L + W - R) / 2:.0f}" y="{H - 14}" text-anchor="middle" fill="#52514e">'
           'dBFS, RMS over the pauses (4 × 2.2 s)</text>')
for j, (key, label, colour, hollow) in enumerate(SERIES):
    lx, ly = L + (j % 2) * 280, 16 + (j // 2) * 20
    fill = "#fcfcfb" if hollow else colour
    out.append(f'<circle cx="{lx + 6}" cy="{ly}" r="5" fill="{fill}" stroke="{colour}" stroke-width="2"/>')
    out.append(f'<text x="{lx + 16}" y="{ly + 4}" fill="#0b0b0b">{label}</text>')
for i, r in enumerate(rows):
    y = T + ROW * i + ROW / 2
    if i % 2 == 0:
        out.append(f'<rect x="0" y="{y - ROW / 2:.1f}" width="{W}" height="{ROW}" fill="#f4f3f0"/>')
    out.append(f'<text x="{L - 10}" y="{y + 4:.1f}" text-anchor="end" fill="#0b0b0b">'
               f'{r["medium"].replace("_", " ")} · {r["case"].replace("_", " ")}</text>')
    vals = {"gap_floor": r["gap_floor"], **{k: r[k]["gap_err"] for k in ("s16", "s16_tpdf", "s24")}}
    known = [v for v in vals.values() if v > -300]
    if known:
        out.append(f'<line x1="{x(min(known)):.1f}" y1="{y:.1f}" x2="{x(max(known)):.1f}" y2="{y:.1f}" stroke="#c9c8c2"/>')
    if any(vals[key] <= -300 for key, _, _, _ in SERIES):
        out.append(f'<text x="{x(-87):.1f}" y="{y + 4:.1f}" fill="#52514e">silent pauses: '
                   '16 and 24-bit keep them exact; dither fills them with noise</text>')
    for key, label, colour, hollow in SERIES:
        v = vals[key]
        if v <= -300:
            continue
        fill = "#fcfcfb" if hollow else colour
        out.append(f'<circle cx="{x(v):.1f}" cy="{y:.1f}" r="5" fill="{fill}" stroke="{colour}" stroke-width="2">'
                   f'<title>{label}: {"digital silence" if v <= -300 else f"{v} dBFS"}</title></circle>')
out.append("</svg>")
path = os.path.join(HERE, "..", "img", "01-error-vs-floor.svg")
open(path, "w").write("\n".join(out))
print("wrote", os.path.normpath(path))
