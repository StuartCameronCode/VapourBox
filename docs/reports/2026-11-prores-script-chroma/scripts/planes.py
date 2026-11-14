#!/usr/bin/env python3
"""Plane arithmetic on raw planar YUV files, in plain Python (the deps bundle
has no NumPy, and nothing here needs it).

  planes.py down IN OUT W H FMT MODE   chroma downsample, same depth
        MODE p420  4:2:2 -> 4:2:0, progressive: rows 2k, 2k+1 averaged
                   (chroma centred vertically, as MPEG-2/H.264 4:2:0 is)
        MODE i420  4:2:2 -> 4:2:0, interlaced, MPEG-2 field siting: chroma row
                   k belongs to field k % 2; top-field samples sit 1/4 of the
                   way between their two field rows, bottom-field ones 3/4
        MODE h422  4:4:4 -> 4:2:2, [1 2 1]/4 centred on the even columns
                   (horizontally co-sited, "left", as MPEG-2/H.264 is)
        MODE p420h 4:4:4 -> 4:2:0: h422 then p420
  planes.py cmp A B W H FMT [PLANES]  PSNR / mean / max abs error per plane, A vs B
  planes.py cmpref A FMT_A REF FMT_REF W H  A (lower depth) against REF scaled
        to A's depth in floating point: RMS and max error, in A's units
  planes.py rows FILE W H FMT PLANE COL R0 R1   sample values down one column
  planes.py fine FILE W H FMT   share of luma samples that are not multiples
        of 4 (an 8-bit picture padded to 10 bits has none)
  planes.py gen16 OUT W H N     yuv422p16le: smooth gradients plus mild noise
  planes.py hotspot A B W H FMT SIZE   the SIZE x SIZE block of the first
        frame's U plane where A and B differ most: prints "x y" (chroma pixels)
"""
import math
import random
import sys
from array import array


def fmt_info(fmt):
    """(subsampling_w, subsampling_h, bits, bytes_per_sample) for a planar YUV
    ffmpeg pix_fmt name."""
    base = fmt.replace("le", "")
    layout = base[3:6]
    bits = int(base[7:]) if len(base) > 7 else 8
    ss = {"420": (1, 1), "422": (1, 0), "444": (0, 0)}[layout]
    return ss[0], ss[1], bits, 1 if bits == 8 else 2


def plane_dims(w, h, fmt):
    sw, sh, _, _ = fmt_info(fmt)
    return [(w, h), (w >> sw, h >> sh), (w >> sw, h >> sh)]


def read_frames(path, w, h, fmt):
    """Yields frames as [Y, U, V] lists of array('H') (or bytes for 8-bit)."""
    _, _, _, bps = fmt_info(fmt)
    dims = plane_dims(w, h, fmt)
    sizes = [pw * ph * bps for pw, ph in dims]
    with open(path, "rb") as f:
        while True:
            planes = []
            for size in sizes:
                data = f.read(size)
                if len(data) < size:
                    return
                if bps == 1:
                    planes.append(array("H", iter(data)))
                else:
                    a = array("H")
                    a.frombytes(data)
                    if sys.byteorder != "little":
                        a.byteswap()
                    planes.append(a)
            yield planes


def write_frame(f, planes, fmt):
    _, _, _, bps = fmt_info(fmt)
    for p in planes:
        if bps == 1:
            f.write(bytes(p))
        else:
            a = array("H", p)
            if sys.byteorder != "little":
                a.byteswap()
            f.write(a.tobytes())


def rnd(x):
    return int(math.floor(x + 0.5))


def down_v_progressive(p, pw, ph):
    out = array("H")
    for k in range(ph // 2):
        r0, r1 = 2 * k * pw, (2 * k + 1) * pw
        out.extend(rnd((p[r0 + x] + p[r1 + x]) / 2) for x in range(pw))
    return out


def down_v_interlaced(p, pw, ph):
    # Field f's rows are frame rows 2j + f. 4:2:0 chroma row k is field
    # f = k % 2's sample m = k // 2, between that field's rows 2m and 2m + 1.
    out = array("H")
    for k in range(ph // 2):
        f, m = k % 2, k // 2
        a = (2 * (2 * m) + f) * pw       # field row 2m
        b = (2 * (2 * m + 1) + f) * pw   # field row 2m + 1
        wa, wb = (0.75, 0.25) if f == 0 else (0.25, 0.75)
        out.extend(rnd(wa * p[a + x] + wb * p[b + x]) for x in range(pw))
    return out


def down_h_left(p, pw, ph):
    out = array("H")
    for y in range(ph):
        row = p[y * pw:(y + 1) * pw]
        for x in range(0, pw, 2):
            l = row[x - 1] if x > 0 else row[x + 1]
            r = row[x + 1] if x + 1 < pw else row[x - 1]
            out.append(rnd((l + 2 * row[x] + r) / 4))
    return out


def cmd_down(src, dst, w, h, fmt, mode):
    with open(dst, "wb") as f:
        for y, u, v in read_frames(src, w, h, fmt):
            cw, ch = plane_dims(w, h, fmt)[1]
            outs = []
            for c in (u, v):
                if mode == "p420":
                    outs.append(down_v_progressive(c, cw, ch))
                elif mode == "i420":
                    outs.append(down_v_interlaced(c, cw, ch))
                elif mode == "h422":
                    outs.append(down_h_left(c, cw, ch))
                elif mode == "p420h":
                    hh = down_h_left(c, cw, ch)
                    outs.append(down_v_progressive(hh, cw // 2, ch))
                else:
                    raise SystemExit(f"unknown mode {mode}")
            write_frame(f, [y] + outs, fmt)


def cmd_cmp(a, b, w, h, fmt, planes="YUV"):
    _, _, bits, _ = fmt_info(fmt)
    peak = (1 << bits) - 1
    sq = [0.0] * 3
    ab = [0.0] * 3
    mx = [0] * 3
    n = [0] * 3
    for fa, fb in zip(read_frames(a, w, h, fmt), read_frames(b, w, h, fmt)):
        for i in range(3):
            pa, pb = fa[i], fb[i]
            s = t = 0
            m = mx[i]
            for x, y in zip(pa, pb):
                d = x - y
                s += d * d
                t += d if d >= 0 else -d
                if d > m or -d > m:
                    m = abs(d)
            sq[i] += s
            ab[i] += t
            mx[i] = m
            n[i] += len(pa)
    for i, name in enumerate("YUV"):
        if name not in planes:
            continue
        mse = sq[i] / n[i]
        psnr = float("inf") if mse == 0 else 10 * math.log10(peak * peak / mse)
        print(f"{name}: psnr {psnr:7.2f} dB  mean|d| {ab[i] / n[i]:.3f}  "
              f"max|d| {mx[i]}  ({bits}-bit units)")


def cmd_cmpref(a, fa, ref, fr, w, h):
    _, _, ba, _ = fmt_info(fa)
    _, _, br, _ = fmt_info(fr)
    scale = 1 / (1 << (br - ba))
    sq = [0.0] * 3
    mx = [0.0] * 3
    n = [0] * 3
    for pa, pr in zip(read_frames(a, w, h, fa), read_frames(ref, w, h, fr)):
        for i in range(3):
            s = 0.0
            m = mx[i]
            for x, r in zip(pa[i], pr[i]):
                d = x - r * scale
                s += d * d
                if abs(d) > m:
                    m = abs(d)
            sq[i] += s
            mx[i] = m
            n[i] += len(pa[i])
    for i, name in enumerate("YUV"):
        print(f"{name}: rms {math.sqrt(sq[i] / n[i]):.4f}  max {mx[i]:.3f}  "
              f"({ba}-bit units, against the {br}-bit source)")


def cmd_rows(path, w, h, fmt, plane, col, r0, r1):
    frame = next(read_frames(path, w, h, fmt))
    pw = plane_dims(w, h, fmt)["YUV".index(plane)][0]
    p = frame["YUV".index(plane)]
    print(" ".join(str(p[r * pw + col]) for r in range(r0, r1)))


def cmd_fine(path, w, h, fmt):
    total = fine = 0
    for y, _, _ in read_frames(path, w, h, fmt):
        total += len(y)
        fine += sum(1 for v in y if v & 3)
    print(f"luma samples not a multiple of 4: {100 * fine / total:.1f}%")


def cmd_gen16(path, w, h, n):
    rng = random.Random(1)
    cw = w // 2
    with open(path, "wb") as f:
        for t in range(n):
            y = array("H", (min(65535, max(0, int(4096 + 56000 * x / w + 30000 * yy / h / 4
                                                   + rng.gauss(0, 40))))
                            for yy in range(h) for x in range(w)))
            u = array("H", (int(32768 + 12000 * math.sin((x + t) / 37) + rng.gauss(0, 40))
                            for yy in range(h) for x in range(cw)))
            v = array("H", (int(32768 + 12000 * math.cos(yy / 29) + rng.gauss(0, 40))
                            for yy in range(h) for x in range(cw)))
            write_frame(f, [y, u, v], "yuv422p16le")


def cmd_hotspot(a, b, w, h, fmt, size):
    ua = next(read_frames(a, w, h, fmt))[1]
    ub = next(read_frames(b, w, h, fmt))[1]
    cw, ch = plane_dims(w, h, fmt)[1]
    best = (-1, 0, 0)
    for by in range(0, ch - size + 1, size // 2):
        for bx in range(0, cw - size + 1, size // 2):
            t = 0
            for y in range(by, by + size):
                o = y * cw
                t += sum(abs(ua[o + x] - ub[o + x]) for x in range(bx, bx + size))
            best = max(best, (t, bx, by))
    # Even rows, so the crop keeps the field parity.
    print(best[1], best[2] & ~1)


def main():
    a = sys.argv[1:]
    cmd = a[0]
    if cmd == "down":
        cmd_down(a[1], a[2], int(a[3]), int(a[4]), a[5], a[6])
    elif cmd == "cmp":
        cmd_cmp(a[1], a[2], int(a[3]), int(a[4]), a[5], a[6] if len(a) > 6 else "YUV")
    elif cmd == "cmpref":
        cmd_cmpref(a[1], a[2], a[3], a[4], int(a[5]), int(a[6]))
    elif cmd == "rows":
        cmd_rows(a[1], int(a[2]), int(a[3]), a[4], a[5], int(a[6]), int(a[7]), int(a[8]))
    elif cmd == "fine":
        cmd_fine(a[1], int(a[2]), int(a[3]), a[4])
    elif cmd == "hotspot":
        cmd_hotspot(a[1], a[2], int(a[3]), int(a[4]), a[5], int(a[6]))
    elif cmd == "gen16":
        cmd_gen16(a[1], int(a[2]), int(a[3]), int(a[4]))
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
