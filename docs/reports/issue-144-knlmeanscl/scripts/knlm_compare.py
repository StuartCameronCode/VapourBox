"""Compare knlm_depth_probe.py dumps: plain Python 3, no VapourSynth needed.

    knlm_compare.py A_DIR [B_DIR]

For every case prints, per directory, whether it ran and how much it changed
the processed planes (denoise), and with two directories how far A and B are
apart. All figures are mean absolute differences in 8-bit levels (0-255).
"""
import array
import os
import sys

W, H = 320, 240


def planes(path, depth, layout):
    """Read a dump into a list of three flat arrays (one per plane)."""
    a = array.array("B" if depth == 8 else "H")
    with open(path, "rb") as fh:
        a.frombytes(fh.read())
    sub = 2 if layout == "420" else 1
    sizes = [W * H, (W // sub) * (H // sub), (W // sub) * (H // sub)]
    out, i = [], 0
    for s in sizes:
        out.append(a[i:i + s])
        i += s
    return out


def mad(pa, pb, idx, depth):
    scale = 255.0 / ((1 << depth) - 1)
    total = n = 0
    for p in idx:
        for x, y in zip(pa[p], pb[p]):
            total += abs(x - y)
        n += len(pa[p])
    return total / n * scale


def load_status(d):
    st = {}
    for line in open(os.path.join(d, "status.txt")):
        case, rest = line.rstrip("\n").split(" ", 1)
        st[case] = rest
    return st


dirs = sys.argv[1:]
stats = [load_status(d) for d in dirs]
hdr = "case                 | " + " | ".join(f"{os.path.basename(d.rstrip('/'))}: denoise" for d in dirs)
print(hdr + (" | A vs B" if len(dirs) == 2 else ""))
for case in stats[0]:
    depth, layout, channels, device = case.split("_")
    depth = int(depth)
    idx = {"Y": [0], "UV": [1, 2], "YUV": [0, 1, 2]}[channels]
    cells, outs = [], []
    for d, st in zip(dirs, stats):
        r = st.get(case, "missing")
        if r != "ok":
            cells.append(r[:72])
            outs.append(None)
            continue
        src = planes(os.path.join(d, f"src_{depth}_{layout}.raw"), depth, layout)
        out = planes(os.path.join(d, case + ".raw"), depth, layout)
        outs.append(out)
        cells.append(f"{mad(src, out, idx, depth):7.3f}")
    row = f"{case:<20} | " + " | ".join(cells)
    if len(dirs) == 2 and all(o is not None for o in outs):
        row += f" | {mad(outs[0], outs[1], idx, depth):.4f}"
    print(row, flush=True)
