"""Shared helpers for the noise / halo score probe.

Decoding, fixture building and the candidate metrics, all on luma only, in
8-bit units whatever the source's depth. NumPy is the only dependency besides
the bundle's ffmpeg.

Paths: the repo is found from this file's location; ffmpeg defaults to the
bundle in deps/<platform>/ffmpeg/ (override with $FFMPEG / $FFPROBE); scratch
files go to $SCRATCH.
"""
import json
import math
import os
import platform
import subprocess

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..'))
RES = os.path.join(REPO, 'Tests', 'TestResources')


def _platform_id():
    m = platform.machine().lower()
    arch = 'arm64' if m in ('arm64', 'aarch64') else 'x64'
    sysname = {'Darwin': 'macos', 'Linux': 'linux', 'Windows': 'windows'}[platform.system()]
    return f'{sysname}-{arch}'


_FFDIR = os.path.join(REPO, 'deps', _platform_id(), 'ffmpeg')
FFMPEG = os.environ.get('FFMPEG', os.path.join(_FFDIR, 'ffmpeg'))
FFPROBE = os.environ.get('FFPROBE', os.path.join(_FFDIR, 'ffprobe'))


def scratch(*parts):
    s = os.environ.get('SCRATCH')
    if not s:
        raise SystemExit('set SCRATCH to a scratch directory')
    p = os.path.join(s, *parts)
    os.makedirs(os.path.dirname(p) if parts else s, exist_ok=True)
    return p


# --------------------------------------------------------------------------
# Decoding

def probe(path):
    out = subprocess.run([FFPROBE, '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                          'stream=width,height,pix_fmt', '-of', 'json', path],
                         capture_output=True, text=True, check=True).stdout
    s = json.loads(out)['streams'][0]
    return s['width'], s['height'], s['pix_fmt']


def luma(path, start=0.0, count=1, pix_fmt=None):
    """`count` consecutive frames from `start` seconds, luma plane only, as
    float32 in 8-bit units. Decoded in the source's own format and the Y plane
    taken, because a yuv -> gray conversion in swscale expands the range."""
    w, h, src_fmt = probe(path)
    fmt = pix_fmt or src_fmt
    deep = any(fmt.endswith(s) for s in ('9le', '10le', '12le', '14le', '16le'))
    depth = int(''.join(c for c in fmt.split('p')[-1] if c.isdigit()) or 8) if deep else 8
    args = [FFMPEG, '-v', 'error']
    if start > 0:
        args += ['-ss', f'{start:.6f}']
    args += ['-apply_cropping', 'codec', '-i', path, '-map', '0:v:0', '-frames:v', str(count),
             '-f', 'rawvideo', '-pix_fmt', fmt, '-']
    data = subprocess.run(args, capture_output=True, check=True).stdout
    n = count
    size = len(data) // n
    bps = 2 if deep else 1
    frames = []
    for i in range(n):
        raw = data[i * size: i * size + w * h * bps]
        a = np.frombuffer(raw, np.uint16 if deep else np.uint8).reshape(h, w).astype(np.float32)
        if deep:
            a /= float(1 << (depth - 8))
        frames.append(a)
    return frames


# --------------------------------------------------------------------------
# Fixture building (all in float luma, 8-bit units)

def kodak_luma(path):
    """A Kodak PNG as BT.601 limited-range luma."""
    w, h, _ = probe(path)
    data = subprocess.run([FFMPEG, '-v', 'error', '-i', path, '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'],
                          capture_output=True, check=True).stdout
    rgb = np.frombuffer(data, np.uint8).reshape(h, w, 3).astype(np.float32)
    y = 0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2]
    return 16.0 + y * 219.0 / 255.0


def pan(img, w, h, n, step=2, x0=0, y0=0):
    """`n` frames of a `w`x`h` window panned `step` px a frame across `img`."""
    return [img[y0:y0 + h, x0 + step * i: x0 + step * i + w].copy() for i in range(n)]


def gauss_kernel(sigma):
    r = max(1, int(math.ceil(3 * sigma)))
    x = np.arange(-r, r + 1, dtype=np.float64)
    k = np.exp(-x * x / (2 * sigma * sigma))
    return (k / k.sum()).astype(np.float32)


def blur_x(a, sigma):
    k = gauss_kernel(sigma)
    r = len(k) // 2
    p = np.pad(a, ((0, 0), (r, r)), mode='edge')
    out = np.zeros_like(a)
    for i, kv in enumerate(k):
        out += kv * p[:, i:i + a.shape[1]]
    return out


def blur_y(a, sigma):
    return blur_x(a.T, sigma).T


def blur(a, sigma):
    return blur_y(blur_x(a, sigma), sigma)


def unsharp(a, radius, amount, horizontal_only=False):
    """Unsharp mask: a + amount * (a - gaussian(a, radius))."""
    b = blur_x(a, radius) if horizontal_only else blur(a, radius)
    return a + amount * (a - b)


def add_noise(frames, sigma, seed=1, corr_x=0.0, corr_xy=0.0, luma_dependent=False):
    """Independent noise per frame with standard deviation `sigma` (8-bit
    levels). `corr_x` blurs it horizontally first (tape noise is band-limited
    along the line); `corr_xy` blurs it in both directions (film grain clumps);
    the result is rescaled to `sigma` either way. `luma_dependent` scales it
    by a mid-tone weighting, as film grain is strongest in the mid-tones."""
    rng = np.random.default_rng(seed)
    out = []
    for f in frames:
        n = rng.standard_normal(f.shape).astype(np.float32)
        if corr_x > 0:
            n = blur_x(n, corr_x)
        if corr_xy > 0:
            n = blur(n, corr_xy)
        n *= sigma / max(1e-6, float(n.std()))
        if luma_dependent:
            t = np.clip((f - 16.0) / 219.0, 0, 1)
            n *= 0.4 + 2.4 * t * (1 - t)
        out.append(f + n)
    return out


def quantize(frames, bits=8, lo=0.0, hi=255.0):
    q = float(1 << (bits - 8))
    return [np.clip(np.round(f * q) / q, lo, hi + (q - 1) / q) for f in frames]


def write_ffv1(frames, path, bits=8, fps=25, interlaced=None):
    """Lossless FFV1 (4:2:0, neutral chroma). `interlaced` = 'tff' tags it."""
    h, w = frames[0].shape
    q = 1 << (bits - 8)
    dt = np.uint16 if bits > 8 else np.uint8
    neutral = 128 * q
    pix = 'yuv420p' if bits == 8 else f'yuv420p{bits}le'
    args = [FFMPEG, '-v', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', pix, '-s', f'{w}x{h}',
            '-r', str(fps), '-i', '-']
    if interlaced:
        args += ['-vf', f'setfield={interlaced}', '-field_order', 'tt' if interlaced == 'tff' else 'bb']
    args += ['-c:v', 'ffv1', '-level', '3', '-pix_fmt', pix, path]
    p = subprocess.Popen(args, stdin=subprocess.PIPE)
    c = np.full((h // 2) * (w // 2), neutral, dt).tobytes()
    for f in frames:
        y = np.clip(np.round(f * q), 0, 255 * q + q - 1).astype(dt)
        p.stdin.write(y.tobytes() + c + c)
    p.stdin.close()
    if p.wait() != 0:
        raise RuntimeError(f'encoding {path}')


# --------------------------------------------------------------------------
# Candidate noise metrics

_SQ = math.sqrt(math.pi / 2) / 6.0


def immerkaer_response(a):
    """|a * M| for Immerkaer's mask M = [1 -2 1; -2 4 -2; 1 -2 1] (interior)."""
    r = (a[:-2, :-2] - 2 * a[:-2, 1:-1] + a[:-2, 2:]
         - 2 * a[1:-1, :-2] + 4 * a[1:-1, 1:-1] - 2 * a[1:-1, 2:]
         + a[2:, :-2] - 2 * a[2:, 1:-1] + a[2:, 2:])
    return np.abs(r)


def fields(a, interlaced):
    return [a[0::2], a[1::2]] if interlaced else [a]


def noise_whole(a, interlaced=False):
    """Immerkaer (1996) over the whole picture."""
    return float(np.mean([_SQ * immerkaer_response(f).mean() for f in fields(a, interlaced)]))


def block_sigmas(a, block=16, black=16.0, white=235.0, margin=4.0):
    """Immerkaer per block, with each block's mean. Blocks whose mean is within
    `margin` of black or white are left out (clipping hides noise there)."""
    r = immerkaer_response(a)
    m = a[1:-1, 1:-1]
    H = (r.shape[0] // block) * block
    W = (r.shape[1] // block) * block
    rb = r[:H, :W].reshape(H // block, block, W // block, block).mean(axis=(1, 3))
    mb = m[:H, :W].reshape(H // block, block, W // block, block).mean(axis=(1, 3))
    keep = (mb > black + margin) & (mb < white - margin)
    return (_SQ * rb[keep]).ravel(), keep.size


def noise_blocks(a, interlaced=False, pct=10, block=16, black=16.0, margin=4.0):
    """A low percentile of per-block Immerkaer estimates: the flattest parts of
    the picture, where the high-pass is noise rather than detail."""
    vals = []
    for f in fields(a, interlaced):
        s, total = block_sigmas(f, block=block, black=black, margin=margin)
        if s.size >= max(8, total // 20):
            vals.append(float(np.percentile(s, pct)))
    return float(np.mean(vals)) if vals else float('nan')


def downsample(a, fx=2, fy=1):
    """Box-average `fx` x `fy` pixels into one. White noise drops by
    sqrt(fx*fy); noise correlated over that span much less."""
    h = (a.shape[0] // fy) * fy
    w = (a.shape[1] // fx) * fx
    return a[:h, :w].reshape(h // fy, fy, w // fx, fx).mean(axis=(1, 3))


def noise_blocks_coarse(a, interlaced=False, pct=10, fx=2, fy=1, block=16):
    """noise_blocks at a coarser scale, rescaled so white noise reads the same
    as at full scale."""
    vals = []
    for f in fields(a, interlaced):
        d = downsample(f, fx, fy)
        s, total = block_sigmas(d, block=block)
        if s.size >= max(8, total // 20):
            vals.append(float(np.percentile(s, pct)) * math.sqrt(fx * fy))
    return float(np.mean(vals)) if vals else float('nan')


def plane_sigmas(a, block=16, black=16.0, white=235.0, margin=4.0):
    """Per block: the standard deviation left after a least-squares plane
    (mean + horizontal + vertical slope) is taken out, with each block's mean.
    Unlike a high-pass, this sees noise at every spatial frequency, so noise
    that is band-limited along the line (tape) or clumped (grain) counts in
    full."""
    H = (a.shape[0] // block) * block
    W = (a.shape[1] // block) * block
    b = a[:H, :W].reshape(H // block, block, W // block, block).transpose(0, 2, 1, 3)
    c = (np.arange(block) - (block - 1) / 2).astype(np.float32)
    yy, xx = np.meshgrid(c, c, indexing='ij')
    m = b.mean(axis=(2, 3))
    sx = (b * xx).sum(axis=(2, 3)) / (xx * xx).sum()
    sy = (b * yy).sum(axis=(2, 3)) / (yy * yy).sum()
    r = b - m[..., None, None] - sx[..., None, None] * xx - sy[..., None, None] * yy
    sd = np.sqrt((r * r).sum(axis=(2, 3)) / (block * block - 3))
    keep = (m > black + margin) & (m < white - margin)
    return sd[keep].ravel(), keep.size


def noise_plane(a, interlaced=False, pct=10, block=16, black=16.0, margin=4.0):
    vals = []
    for f in fields(a, interlaced):
        s, total = plane_sigmas(f, block=block, black=black, margin=margin)
        if s.size >= max(8, total // 20):
            vals.append(float(np.percentile(s, pct)))
    return float(np.mean(vals)) if vals else float('nan')


def box3(a):
    p = np.pad(a, 1, mode='edge')
    return sum(p[i:i + a.shape[0], j:j + a.shape[1]] for i in range(3) for j in range(3)) / 9.0


def noise_mc(a, b, interlaced=False, pct=10, block=16, radius=6, black=16.0, white=235.0, margin=4.0):
    """Motion-compensated temporal estimate. Each block of `a` is matched in
    `b` within +-radius px, the match chosen on 3x3-smoothed pictures (so the
    choice barely depends on the noise being measured); then
    std(a - matched b) / sqrt 2 on the unsmoothed ones. Sees noise at every
    spatial frequency, and texture that moved cancels. A low percentile over
    blocks, as for the spatial estimate."""
    vals = []
    for fa, fb in zip(fields(a, interlaced), fields(b, interlaced)):
        h, w = fa.shape
        by = (h - 2 * radius) // block
        bx = (w - 2 * radius) // block
        if by < 2 or bx < 2:
            continue
        y0 = x0 = radius
        H, W = by * block, bx * block
        sa, sb = box3(fa), box3(fb)
        ca = sa[y0:y0 + H, x0:x0 + W]
        best = np.full((by, bx), np.inf, np.float32)
        best_d = np.zeros((by, bx), np.float32)
        ra = fa[y0:y0 + H, x0:x0 + W]
        for dy in range(-radius, radius + 1):
            for dx in range(-radius, radius + 1):
                cb = sb[y0 + dy:y0 + dy + H, x0 + dx:x0 + dx + W]
                sad = np.abs(ca - cb).reshape(by, block, bx, block).mean(axis=(1, 3))
                d = (ra - fb[y0 + dy:y0 + dy + H, x0 + dx:x0 + dx + W]).reshape(by, block, bx, block)
                sd = d.std(axis=(1, 3)) / math.sqrt(2)
                better = sad < best
                best = np.where(better, sad, best)
                best_d = np.where(better, sd, best_d)
        mb = ra.reshape(by, block, bx, block).mean(axis=(1, 3))
        keep = (mb > black + margin) & (mb < white - margin)
        if keep.sum() >= max(8, keep.size // 20):
            vals.append(float(np.percentile(best_d[keep], pct)))
    return float(np.mean(vals)) if vals else float('nan')


def subpixel_pan(img, w, h, n, step, y0=0):
    """A pan by a non-integer `step` px a frame (cubic interpolation along x),
    so motion compensation at whole pixels cannot cancel texture exactly."""
    out = []
    for i in range(n):
        x = step * i
        xi = int(math.floor(x))
        t = x - xi
        # Catmull-Rom weights
        wts = [(-t + 2 * t * t - t ** 3) / 2, (2 - 5 * t * t + 3 * t ** 3) / 2,
               (t + 4 * t * t - 3 * t ** 3) / 2, (-t * t + t ** 3) / 2]
        row = img[y0:y0 + h]
        f = sum(wv * row[:, xi + k:xi + k + w] for k, wv in zip(range(4), wts))
        out.append(f.astype(np.float32))
    return out


def noise_temporal(a, b, interlaced=False, pct=10, block=16, black=16.0, margin=4.0):
    """Frame difference over the blocks that changed least: std(b - a) / sqrt(2)."""
    vals = []
    for fa, fb in zip(fields(a, interlaced), fields(b, interlaced)):
        d = fb - fa
        H = (d.shape[0] // block) * block
        W = (d.shape[1] // block) * block
        db = d[:H, :W].reshape(H // block, block, W // block, block)
        mb = fa[:H, :W].reshape(H // block, block, W // block, block).mean(axis=(1, 3))
        sd = db.std(axis=(1, 3)) / math.sqrt(2)
        keep = (mb > black + margin) & (mb < 235 - margin)
        if keep.sum() >= 8:
            vals.append(float(np.percentile(sd[keep], pct)))
    return float(np.mean(vals)) if vals else float('nan')


# --------------------------------------------------------------------------
# Candidate halo metrics

def edge_profiles(a, noise=0.0, t_edge=None, d1=6, d2=10, min_step=None, row_step=1):
    """Every isolated horizontal step edge in `a`: rows scanned along the line
    (field-safe), an edge where |a[x+1] - a[x-1]| is a local maximum and large,
    with flat plateaus d1..d2 px out on both sides that differ by enough.
    Returns the profiles oriented bright-side-positive and normalised so the
    dark plateau is 0 and the bright one 1, shape (n, 2*d2+1)."""
    t_edge = t_edge if t_edge is not None else max(20.0, 6.0 * noise)
    min_step = min_step if min_step is not None else max(30.0, 8.0 * noise)
    flat = max(2.5, 1.6 * noise)
    rows = a[::row_step]
    h, w = rows.shape
    g = np.zeros_like(rows)
    g[:, 1:-1] = rows[:, 2:] - rows[:, :-2]
    ag = np.abs(g)
    peak = np.zeros_like(rows, dtype=bool)
    peak[:, 1:-1] = (ag[:, 1:-1] >= ag[:, :-2]) & (ag[:, 1:-1] > ag[:, 2:]) & (ag[:, 1:-1] >= t_edge)
    peak[:, :d2 + 1] = False
    peak[:, w - d2 - 1:] = False
    ys, xs = np.nonzero(peak)
    if ys.size == 0:
        return np.zeros((0, 2 * d2 + 1), np.float32)
    offs = np.arange(-d2, d2 + 1)
    prof = rows[ys[:, None], xs[:, None] + offs[None, :]]
    sign = np.sign(g[ys, xs])
    prof = np.where(sign[:, None] > 0, prof, prof[:, ::-1])
    far_d = prof[:, :d2 - d1 + 1]
    far_b = prof[:, d2 + d1:]
    fd, fb = far_d.mean(axis=1), far_b.mean(axis=1)
    ok = (far_d.std(axis=1) <= flat) & (far_b.std(axis=1) <= flat) & (fb - fd >= min_step)
    prof, fd, fb = prof[ok], fd[ok], fb[ok]
    return ((prof - fd[:, None]) / (fb - fd)[:, None]).astype(np.float32)


def halo_from_profiles(p, d1=6, d2=10):
    """Overshoot past the bright plateau and undershoot below the dark one, in
    the mean profile, as % of the step. A halo is two-sided; an outline (a dark
    line beside a fill) is one-sided."""
    if p.shape[0] == 0:
        return dict(edges=0, over=float('nan'), under=float('nan'), score=float('nan'))
    m = p.mean(axis=0)
    c = d2
    over = float(m[c + 1:c + d1].max() - 1.0) * 100
    under = float(-m[c - d1 + 1:c].min()) * 100
    return dict(edges=int(p.shape[0]), over=over, under=under, score=min(over, under))


def halo_vcg_like(a, edge=40, over_t=14, flat_range=20):
    """The idea of VCG Deinterlacer's analyze_halo_level (fraction of strong
    edges with a two-sided overshoot in 4..7 px against a plateau 11..14 px
    out), re-expressed in NumPy for comparison. Not used by VapourBox.
    VCG Deinterlacer: MIT License, Copyright (c) 2026 Video-Capture-Guide
    (vcg_deinterlacer_v130.py); its thresholds (40, 14, 20) are kept."""
    h, w = a.shape
    total = halo = 0

    def probe_at(x, y):
        grad = a[y, x + 2] - a[y, x - 2]
        if abs(grad) < edge:
            return None
        b, d = (1, -1) if grad > 0 else (-1, 1)
        bn = max(a[y, x + b * k] for k in range(4, 8))
        bf = [a[y, x + b * k] for k in range(11, 15)]
        dn = min(a[y, x + d * k] for k in range(4, 8))
        df = [a[y, x + d * k] for k in range(11, 15)]
        if max(bf) - min(bf) > flat_range or max(df) - min(df) > flat_range:
            return None
        return (bn - sum(bf) / 4 >= over_t) and (sum(df) / 4 - dn >= over_t * 0.7)

    for y in range(h // 8, h * 7 // 8 - 2, 4):
        x = 16
        while x < w - 16:
            here = probe_at(x, y)
            if here is None:
                x += 2
                continue
            below = None
            for dx in (0, -1, 1, -2, 2):
                if 16 <= x + dx < w - 16:
                    below = probe_at(x + dx, y + 2)
                    if below is not None:
                        break
            if below is not None:
                total += 1
                if here and below:
                    halo += 1
            x += 10
    return dict(edges=total, ratio=(halo / total) if total else float('nan'))


def coherent_edges(a, noise=0.0, interlaced=False, d1=6, d2=10, t_edge=None, min_step=None,
                   profiles=False, flat=None, reach=1, flat_rel=0.0):
    """Per-edge halo measurements on isolated, vertically coherent step edges.

    An edge is a local maximum of |a[x+1] - a[x-1]| along a line, at least
    `t_edge`, that continues on the lines above and below in the same field
    (within a pixel, same sign): texture rarely does, a picture edge does. The
    three lines' profiles, each centred on its own edge, are averaged (noise
    down by sqrt 3), oriented bright side positive, and kept when both
    plateaus `d1..d2` px out are flat and differ by `min_step`.

    For each kept edge, in units of its step:
      over  = max(near bright zone, 1..d1-1) - max(far bright plateau)
      under = min(far dark plateau) - min(near dark zone)
    Near and far zones have the same number of samples, so noise lifts the max
    (and lowers the min) of both alike and cancels in the difference.
    Returns an array of shape (n, 2): over, under."""
    t_edge = t_edge if t_edge is not None else max(16.0, 5.0 * noise)
    min_step = min_step if min_step is not None else max(24.0, 8.0 * noise)
    flat = flat if flat is not None else max(2.0, 2.0 * noise / math.sqrt(2 * reach + 1))
    out = []
    offs = np.arange(-d2, d2 + 1)
    for f in fields(a, interlaced):
        h, w = f.shape
        g = np.zeros_like(f)
        g[:, 1:-1] = f[:, 2:] - f[:, :-2]
        ag = np.abs(g)
        peak = np.zeros_like(f, dtype=bool)
        peak[1:-1, 1:-1] = ((ag[1:-1, 1:-1] >= ag[1:-1, :-2]) & (ag[1:-1, 1:-1] > ag[1:-1, 2:])
                            & (ag[1:-1, 1:-1] >= t_edge))
        peak[:, :d2 + reach + 2] = False
        peak[:, w - d2 - reach - 2:] = False
        peak[:reach, :] = False
        peak[h - reach:, :] = False
        ys, xs = np.nonzero(peak)
        if ys.size == 0:
            continue
        s = np.sign(g[ys, xs])
        ok = np.ones(ys.size, bool)
        rows = [(ys, xs)]
        for direction in (-1, 1):
            px = xs
            for k in range(1, reach + 1):
                yy = ys + direction * k
                cand = np.stack([ag[yy, px + dx] * (np.sign(g[yy, px + dx]) == s) for dx in (-1, 0, 1)])
                best = cand.argmax(axis=0)
                ok &= cand.max(axis=0) >= t_edge * 0.5
                px = px + best - 1
                rows.append((yy, px))
        prof = np.mean([f[yy[:, None], xx[:, None] + offs[None, :]] for yy, xx in rows], axis=0)
        prof = np.where(s[:, None] > 0, prof, prof[:, ::-1])[ok]
        c = d2
        far_d = prof[:, :d2 - d1 + 1]
        far_b = prof[:, c + d1:]
        fd, fb = far_d.mean(axis=1), far_b.mean(axis=1)
        tol = np.maximum(flat, flat_rel * (fb - fd))
        keep = (far_d.std(axis=1) <= tol) & (far_b.std(axis=1) <= tol) & (fb - fd >= min_step)
        prof, fd, fb, far_d, far_b = prof[keep], fd[keep], fb[keep], far_d[keep], far_b[keep]
        hgt = fb - fd
        if profiles:
            out.append((prof - fd[:, None]) / hgt[:, None])
            continue
        near_b = prof[:, c + 1:c + d1]
        near_d = prof[:, c - d1 + 1:c]
        over = (near_b.max(axis=1) - far_b.max(axis=1)) / hgt
        under = (far_d.min(axis=1) - near_d.min(axis=1)) / hgt
        out.append(np.stack([over, under], axis=1))
    if not out:
        return np.zeros((0, 2 * d2 + 1 if profiles else 2), np.float32)
    return np.concatenate(out)


def halo_mean_zone(p, near=(2, 4), d1=6, d2=10):
    """From normalised coherent profiles: the mean over edges of (near-zone
    mean - plateau) on the bright side, and of (plateau - near-zone mean) on
    the dark side, in % of the step; the score is the smaller. Means, so noise
    adds no bias; a one-sided feature (an outline) scores 0."""
    if p.shape[0] == 0:
        return dict(edges=0, score=float('nan'), over=float('nan'), under=float('nan'))
    c = d2
    a, b = near
    o = p[:, c + a:c + b + 1].mean(axis=1) - p[:, c + d1:].mean(axis=1)
    u = p[:, :d2 - d1 + 1].mean(axis=1) - p[:, c - b:c - a + 1].mean(axis=1)
    O, U = float(o.mean() * 100), float(u.mean() * 100)
    return dict(edges=int(p.shape[0]), score=min(O, U), over=O, under=U)


def halo_score(ou, frac_at=0.08):
    """From coherent_edges: the mean two-sided halo (min of over and under, %
    of the step) and the share of edges whose two-sided halo exceeds
    `frac_at`."""
    if ou.shape[0] == 0:
        return dict(edges=0, score=float('nan'), frac=float('nan'), over=float('nan'),
                    under=float('nan'), median=float('nan'))
    two = np.minimum(ou[:, 0], ou[:, 1])
    return dict(edges=int(ou.shape[0]), score=float(two.mean() * 100), frac=float((two > frac_at).mean()),
                over=float(ou[:, 0].mean() * 100), under=float(ou[:, 1].mean() * 100),
                median=float(np.median(two) * 100))


# --------------------------------------------------------------------------
# The chosen measurement, exactly as worker/src/noise_halo.rs does it.

NOISE_HIGH = 3.5      # 8-bit levels
HALO_HIGH = 6.0       # % of the step
HALO_MIN_EDGES = 200
HALO_FLAT_REL = 0.03  # plateau flatness may also be 3% of the step
NOISE_PAIR_PCT = 25   # percentile over sampled frame pairs
MC_BLOCK = 16
MC_COARSE = 5         # search radius at half resolution: +-10 px
MC_MARGIN = 2 * MC_COARSE + 1
MC_MAX_BLOCKS = 4096


def _box3_edge(a):
    p = np.pad(a, 1, mode='edge')
    return sum(p[i:i + a.shape[0], j:j + a.shape[1]] for i in range(3) for j in range(3)) / 9.0


def _half(a):
    h, w = (a.shape[0] // 2) * 2, (a.shape[1] // 2) * 2
    return a[:h, :w].reshape(h // 2, 2, w // 2, 2).mean(axis=(1, 3))


def final_mc_field(f, g, black, white):
    """Motion-compensated noise sigma of one field (or progressive frame) `f`
    against the same field of the next frame `g`, or None. Each 16x16 block is
    matched at half resolution within +-5 (+-10 px), refined +-1 px at full
    resolution, the match chosen on 3x3 box-smoothed pictures; its sigma is
    std(f - matched g) / sqrt 2 on the raw ones. The 10th percentile over
    blocks not within 4 levels of black or white."""
    h, w = f.shape
    B, M = MC_BLOCK, MC_MARGIN
    by, bx = (h - 2 * M) // B, (w - 2 * M) // B
    if by < 2 or bx < 2:
        return None
    stride = 1
    while (by // stride) * (bx // stride) > MC_MAX_BLOCKS:
        stride += 1
    sf, sg = _box3_edge(f), _box3_edge(g)
    cf, cg = _box3_edge(_half(f)), _box3_edge(_half(g))
    sig = []
    for i in range(0, by, stride):
        for j in range(0, bx, stride):
            y, x = M + i * B, M + j * B
            # Coarse: block of 8 at (y/2, x/2).
            cy, cx = y // 2, x // 2
            ref = cf[cy:cy + B // 2, cx:cx + B // 2]
            best, bv = None, (0, 0)
            for dy in range(-MC_COARSE, MC_COARSE + 1):
                for dx in range(-MC_COARSE, MC_COARSE + 1):
                    s = np.abs(ref - cg[cy + dy:cy + dy + B // 2, cx + dx:cx + dx + B // 2]).sum()
                    if best is None or s < best:
                        best, bv = s, (dy, dx)
            ref = sf[y:y + B, x:x + B]
            best, fv = None, (0, 0)
            for ry in (-1, 0, 1):
                for rx in (-1, 0, 1):
                    dy, dx = 2 * bv[0] + ry, 2 * bv[1] + rx
                    s = np.abs(ref - sg[y + dy:y + dy + B, x + dx:x + dx + B]).sum()
                    if best is None or s < best:
                        best, fv = s, (dy, dx)
            raw = f[y:y + B, x:x + B]
            m = raw.mean()
            if not (black + 4.0 < m < white - 4.0):
                continue
            d = raw - g[y + fv[0]:y + fv[0] + B, x + fv[1]:x + fv[1] + B]
            sig.append(float(d.std()) / math.sqrt(2))
    total = len(range(0, by, stride)) * len(range(0, bx, stride))
    if len(sig) < max(8, total // 20):
        return None
    return float(np.percentile(sig, 10, method='lower'))


def final_pair(a, b, interlaced=False, full_range=False):
    """One sampled pair of consecutive frames: (noise sigma or None, list of
    per-edge two-sided halos in both frames)."""
    black, white = (0.0, 255.0) if full_range else (16.0, 235.0)
    sig = [final_mc_field(fa, fb, black, white) for fa, fb in zip(fields(a, interlaced), fields(b, interlaced))]
    sigma = None if any(s is None for s in sig) else float(np.mean(sig))
    halos = []
    for f in (a, b):
        ou = coherent_edges(f, sigma or 0.0, interlaced, d1=6, d2=10, reach=3, flat_rel=HALO_FLAT_REL)
        halos += list(np.minimum(ou[:, 0], ou[:, 1]))
    return sigma, halos


def final_source(pairs, interlaced=False, full_range=False):
    sigmas, halos = [], []
    for a, b in pairs:
        s, h = final_pair(a, b, interlaced, full_range)
        if s is not None:
            sigmas.append(s)
        halos += h
    noise = float(np.percentile(sigmas, NOISE_PAIR_PCT, method='lower')) if sigmas else None
    halo = float(np.mean(halos) * 100) if len(halos) >= HALO_MIN_EDGES else None
    return dict(noise=noise, halo=halo, halo_edges=len(halos), usable=len(sigmas),
                noise_high=noise is not None and noise >= NOISE_HIGH,
                halo_high=halo is not None and halo >= HALO_HIGH)
